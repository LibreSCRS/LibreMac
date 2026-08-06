// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// `@Observable` view model that drives the menu-bar UI. A pure client of the
// local agent: it owns NO card session and touches NO PC/SC. It consumes the
// `AgentClient` registry / availability / quiescence streams and folds them
// into a single `Presence` value the views render. All wire work happens on
// the `AgentClient` actor; this view model only `await`s it, so nothing ever
// blocks the main thread.
//
// It also drives the optional `TokenIdentityRegistrar`: once a signing
// card's certificates are read, the signing-capable ones are resolved to DER
// and published; on removal (or a same-frame swap to a different card) any
// previously published identity is cleared. See "Token identity publishing"
// below.

import Foundation
import LibreMacAgentClient
import Observation
import os

@Observable
@MainActor
public final class CardMonitor {

    // MARK: - Observable surface

    /// The single high-level state the menu-bar icon and `CardStatusView`
    /// switch over. Derived from `available` + registry + `quiescedReason`.
    public private(set) var presence: Presence = .agentUnavailable

    public private(set) var readers: [ReaderState] = []
    public private(set) var cards: [CardState] = []
    /// Certificates read from the current PKI card (empty until the read op
    /// completes; cleared when the card changes or the agent vanishes).
    public private(set) var certificates: [CertificateInfo] = []
    /// The connected agent's `HelloAck.features`, published observably so a
    /// menu body (which cannot `await` the `AgentClient` actor) can gate on
    /// it. Refreshed on every connect — the availability flip follows the
    /// HelloAck, so `agentInfo()` is current by then — and reset to empty on
    /// disconnect.
    public private(set) var agentFeatures: Set<String> = []

    // MARK: - Credentials event taps

    /// Re-publications of every registry snapshot / quiescence event this
    /// monitor consumes. The `AgentClient` streams are UNICAST and this
    /// monitor is their consumer, so the credentials wiring must not iterate
    /// them too — it subscribes to these taps instead. The taps are
    /// themselves unicast `AsyncStream`s with exactly ONE intended consumer:
    /// the `CredentialsClientAdapter` behind the app's single
    /// `CredentialsViewModel`. Nothing else may iterate them.
    public nonisolated let registryUpdatesTap: AsyncStream<RegistrySnapshot>
    /// See `registryUpdatesTap` — same contract, quiescence events.
    public nonisolated let quiescenceTap: AsyncStream<QuiesceReason>
    private nonisolated let registryTapContinuation: AsyncStream<RegistrySnapshot>.Continuation
    private nonisolated let quiescenceTapContinuation: AsyncStream<QuiesceReason>.Continuation

    // MARK: - Derived signing inputs (read by SigningCoordinator / SignDemoView)

    /// The active card iff it is PKI-capable — the card a sign op targets. An
    /// identity-only active card (passport, vehicle) yields `nil`, so Sign hides.
    public var signingCard: CardState? {
        activeCard.flatMap { $0.caps.contains(.pki) ? $0 : nil }
    }

    // MARK: - Reader selection (multi-reader)

    /// Transient app-session selection: the reader HANDLE the user picked.
    /// Never persisted; cleared on agent disconnect. Drives every flow.
    public private(set) var selectedReader: String?

    /// The one card every flow acts on — the selected reader's card if it still
    /// holds one, else the deterministic first. Capability-neutral.
    public var activeCard: CardState? {
        resolveActiveCard(cards: cards, readers: readers, selectedReader: selectedReader)
    }

    /// Picker model: the present cards in deterministic order (one row per card;
    /// a reader holds exactly one card). Shown by the menu picker for >= 2.
    public var readersWithCards: [CardState] {
        sortedCards(cards, readers: readers)
    }

    /// Friendly, disambiguated label for a reader handle (contact/contactless,
    /// serial-tail uniqueness). Served from a map rebuilt when the roster changes.
    public func readerLabel(for readerHandle: String) -> String {
        readerLabelMap[readerHandle] ?? readerHandle
    }

    /// User pick from the picker (transient). Re-targets certs/status/sign.
    public func selectReader(_ readerHandle: String) {
        guard selectedReader != readerHandle else { return }
        selectedReader = readerHandle
        reconcileCertificateReading()
        recomputePresence()
    }

    /// The first signing-capable certificate on the current card.
    public var signingCertId: String? {
        certificates.first(where: { $0.signingCapable })?.certId
    }

    /// Whether a sign can be started right now: agent up, not quiesced, a PKI
    /// card present, and a signing certificate discovered on it. Replaces the
    /// old `activeSession != nil` gate.
    public var canSign: Bool {
        guard available, quiescedReason == nil else { return false }
        return signingCard != nil && signingCertId != nil
    }

    // MARK: - Backing state

    private var available = false
    private var quiescedReason: QuiesceReason?
    private var currentCardHandle: String?
    private var readerLabelMap: [String: String] = [:]
    private var certReadTask: Task<Void, Never>?

    private let client: AgentClient
    /// Publishes the signing card's identities to `ctkd`, in step with card
    /// presence. `nil` in most tests (and any host build that opts out) — the
    /// whole publish/remove path below is then a no-op.
    private let tokenRegistrar: TokenIdentityRegistrar?

    /// Non-isolated holder so `deinit` can cancel the stream-consumer tasks
    /// without crossing the actor boundary (Swift 6 forbids synchronous access
    /// to `@MainActor` state from `deinit`).
    private final class TaskHolder: @unchecked Sendable {
        var tasks: [Task<Void, Never>] = []
    }
    private let taskHolder = TaskHolder()

    public init(client: AgentClient, tokenRegistrar: TokenIdentityRegistrar? = nil) {
        self.client = client
        self.tokenRegistrar = tokenRegistrar
        let (registryTapStream, registryTapContinuation) =
            AsyncStream.makeStream(of: RegistrySnapshot.self)
        self.registryUpdatesTap = registryTapStream
        self.registryTapContinuation = registryTapContinuation
        let (quiescenceTapStream, quiescenceTapContinuation) =
            AsyncStream.makeStream(of: QuiesceReason.self)
        self.quiescenceTap = quiescenceTapStream
        self.quiescenceTapContinuation = quiescenceTapContinuation
        // Capture the Sendable streams before the Task closures so `self`
        // (MainActor-isolated) is not pulled into the stream access itself.
        let registryUpdates = client.registryUpdates
        let availability = client.availability
        let quiescence = client.quiescence

        // These tasks are created in a `@MainActor` context and therefore
        // inherit MainActor isolation: the stream `await`s suspend without
        // blocking the main thread, and the `apply(...)` calls are same-actor
        // (synchronous) mutations of the observable state. The registry and
        // quiescence loops forward each event into the credentials taps
        // BEFORE applying it locally, so the taps' consumer never observes an
        // event later than this monitor did.
        taskHolder.tasks.append(
            Task { [weak self] in
                for await snapshot in registryUpdates {
                    registryTapContinuation.yield(snapshot)
                    guard let self else { return }
                    self.apply(snapshot: snapshot)
                }
            })
        taskHolder.tasks.append(
            Task { [weak self] in
                for await value in availability {
                    // On connect the client has already completed its handshake
                    // (availability flips true only after HelloAck), so the
                    // feature set read here is the freshly acknowledged one.
                    var features: Set<String> = []
                    if value {
                        features = Set(await client.agentInfo().features)
                    }
                    guard let self else { return }
                    self.apply(available: value, features: features)
                }
            })
        taskHolder.tasks.append(
            Task { [weak self] in
                for await reason in quiescence {
                    quiescenceTapContinuation.yield(reason)
                    guard let self else { return }
                    self.apply(quiesced: reason)
                }
            })
    }

    deinit {
        for task in taskHolder.tasks {
            task.cancel()
        }
        registryTapContinuation.finish()
        quiescenceTapContinuation.finish()
    }

    // MARK: - Stream handlers

    private func apply(snapshot: RegistrySnapshot) {
        let readersChanged = snapshot.readers != readers
        readers = snapshot.readers
        cards = snapshot.cards
        if readersChanged { rebuildReaderLabels() }
        // A registry snapshot is "the next presence event" that clears a
        // pending quiesce (the agent emits no explicit un-quiesce).
        quiescedReason = nil
        reconcileCertificateReading()
        recomputePresence()
    }

    private func rebuildReaderLabels() {
        readerLabelMap = readerDisplayLabels(
            readers,
            contact: { Self.ifaceLabel("libremac_reader_iface_contact", "{model} — contact", $0) },
            contactless: { Self.ifaceLabel("libremac_reader_iface_contactless", "{model} — contactless", $0) }
        )
    }

    private static func ifaceLabel(_ key: String, _ fallback: String, _ model: String) -> String {
        AppLocalization.shared.loc(key, fallback, placeholders: ["model": model])
    }

    private func apply(available value: Bool, features: Set<String>) {
        available = value
        agentFeatures = features
        if !value {
            // The client's death sweep already cleared the registry; drop the
            // derived cert state too so no stale "certificates ready" survives.
            certReadTask?.cancel()
            certReadTask = nil
            currentCardHandle = nil
            certificates = []
            // A handle does not survive an agent restart; drop the transient
            // pick so no stale reader handle lingers into a reconnect.
            selectedReader = nil
            readerLabelMap = [:]
        }
        recomputePresence()
    }

    private func apply(quiesced reason: QuiesceReason) {
        quiescedReason = reason
        recomputePresence()
    }

    // MARK: - Certificate reading (the one op this view model drives)

    private func reconcileCertificateReading() {
        let active = activeCard
        guard active?.handle != currentCardHandle else { return }
        currentCardHandle = active?.handle
        certReadTask?.cancel()
        certReadTask = nil
        certificates = []
        // The active card just changed — removed outright, swapped for a
        // different card in the same snapshot, or re-targeted by the user's
        // pick. Either way, remove-on-eject must clear any previously published
        // Keychain identity immediately, not only after (if ever) a new card's
        // certs finish reading.
        tokenRegistrar?.onCardRemoved()
        // Only PKI cards have certificates to read / identities to publish;
        // an identity-only active card (passport, vehicle) leaves certs empty.
        guard let card = active, card.caps.contains(.pki) else { return }
        certReadTask = Task { [weak self] in
            await self?.readCertificates(card: card)
        }
    }

    private func readCertificates(card: CardState) async {
        let cardHandle = card.handle
        do {
            let operation = try await client.readCertificates(card: cardHandle)
            let (status, _, _, _) = await operation.finished()
            guard !Task.isCancelled, currentCardHandle == cardHandle else { return }
            guard status == .ok, let certs = operation.certificatesResult else {
                Logger.card.error(
                    "certificate read did not complete for \(cardHandle, privacy: .public)")
                return
            }
            certificates = certs
            recomputePresence()
            Logger.card.info(
                "Read \(certs.count, privacy: .public) certificates from \(cardHandle, privacy: .public)")

            if let tokenRegistrar {
                let publishable = await Self.publishableCerts(certs, reader: card.reader) {
                    reader, certId in
                    try await client.certificateDer(reader: reader, certId: certId)
                }
                guard !Task.isCancelled, currentCardHandle == cardHandle else { return }
                tokenRegistrar.onCardPresent(certs: publishable)
            }
        } catch {
            Logger.card.error(
                "readCertificates failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Token identity publishing

    /// Resolves a `PublishableCert` for every signing-capable cert in
    /// `certificates`, fetching each one's DER via `fetchDer`. A cert whose
    /// DER fetch fails is skipped (logged) rather than aborting the whole
    /// batch — mirrors `TokenIdentityRegistrar.onCardPresent`'s own
    /// "skip, never crash the presence pipeline" contract.
    ///
    /// Free of any `AgentClient`/stream dependency (`fetchDer` is a plain
    /// closure) so the card-presence -> registrar wiring is unit-testable
    /// with a stub, without a live agent connection.
    static func publishableCerts(
        _ certificates: [CertificateInfo],
        reader: String,
        fetchDer: (_ reader: String, _ certId: String) async throws -> Data
    ) async -> [PublishableCert] {
        var result: [PublishableCert] = []
        for cert in certificates where cert.signingCapable {
            do {
                let der = try await fetchDer(reader, cert.certId)
                // RFC 5280 §4.2.1.3 KeyUsage, natural ordinal bit order (bit
                // 0 = digitalSignature, bit 1 = nonRepudiation /
                // contentCommitment — the qualified-signature flag). This is
                // the same left-shift-by-ordinal convention the agent uses
                // to populate `keyUsageBits` (`KeyUsageBit::NonRepudiation
                // == 1`), not a reversed DER BIT STRING bit order.
                let isQualified = cert.keyUsageBits & (1 << 1) != 0
                result.append(
                    PublishableCert(certId: cert.certId, der: der, isQualified: isQualified))
            } catch {
                Logger.card.error(
                    "certificateDer failed for \(cert.certId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return result
    }

    // MARK: - Presence derivation

    private func recomputePresence() {
        presence = computePresence()
    }

    private func computePresence() -> Presence {
        if !available { return .agentUnavailable }
        if let reason = quiescedReason { return .quiesced(reason) }
        if readers.isEmpty { return .noReader }
        guard let card = activeCard else { return .readerEmpty }
        let state = resolveCardState(
            caps: card.caps, preAuth: card.preAuth, present: true, identityRead: false)
        return .card(state)
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// `@Observable` view model behind the credentials window. A pure client of
// the local agent: it lists a card's credential records, drives the one
// mutation this build exposes (a PIN change), and folds the agent's
// presence events into per-card section lifetime. NO secret ever passes
// through this process — the agent collects the old/new PIN in its own
// secure dialog; the only inputs here are card and record handles, and the
// only outputs the typed results the views render.

import Foundation
import LibreMacAgentClient
import LibreMacShared
import Observation
import os

/// The slice of `AgentClient` the credentials view model needs. Behind a
/// protocol seam so the listing/mutation/event flow is unit-testable with
/// an in-memory mock (the concrete `AgentClient` is an actor whose socket
/// cannot be spun up in a host unit test) — the `AgentSigningClient`
/// precedent. `AgentClient` conforms below.
public protocol AgentCredentialsClient: Sendable {
    /// Whether the connected agent advertises the `"credentials"` feature.
    /// The view model never consults this directly — gating rides on the
    /// ops throwing `.notSupported` at entry, folded into `entryError`;
    /// the menu-level gate is `CardMonitor.agentFeatures`.
    var supportsCredentials: Bool { get async }
    /// Reader/card registry snapshots — a snapshot no longer carrying a
    /// card is that card's removal signal.
    var registryUpdates: AsyncStream<RegistrySnapshot> { get }
    /// Agent quiescence events (sleep / lock / session switch / shutdown).
    var quiescence: AsyncStream<QuiesceReason> { get }

    func listCredentials(card: String) async throws -> AgentOperation
    func managePin(
        card: String, pinId: String, verb: CredentialVerb, activateKey: Bool
    ) async throws -> AgentOperation
    func activateSigningKey(card: String) async throws -> AgentOperation
}

/// `AgentClient` matches the seam as-is: the nonisolated stream properties
/// witness the stream requirements, the actor-isolated `supportsCredentials`
/// witnesses the async getter, and `managePin`'s `activateKey: Bool = false`
/// default satisfies the protocol's no-default requirement.
///
/// `registryUpdates` / `quiescence` are single-consumer `AsyncStream`s that
/// `CardMonitor` also iterates — the composition root must hand this view
/// model its own client (or a fan-out adapter), never share one client's
/// streams between both consumers.
extension AgentClient: AgentCredentialsClient {}

/// One card's credential listing, as the credentials window renders it.
public struct CredentialsCardSection: Sendable, Equatable {
    public let card: String
    public let records: [CredentialRecord]

    public init(card: String, records: [CredentialRecord]) {
        self.card = card
        self.records = records
    }
}

/// A per-record affordance, derived strictly from the record's advertised
/// booleans (`actions(for:)`) — never from local guesses about card family
/// or state. Only `.change` is driven by this view model
/// (`change(card:pinId:)`); the rest are rendering surface for the window.
public enum CredentialAction: Sendable, Equatable {
    case change
    case unblock
    case activatePin
    case activateKey
}

@Observable
@MainActor
public final class CredentialsViewModel {

    // MARK: - Observable surface

    /// One section per card with a completed listing, in first-listed order.
    public private(set) var cards: [CredentialsCardSection] = []
    /// The result of the most recent mutation attempt that reached the
    /// agent. Retained even when the operation terminalizes non-Ok — a
    /// failed attempt's `retriesLeft` arrives exactly this way.
    public private(set) var lastOutcome: CredentialResult?
    /// The most recent request's failure to produce a typed result: an
    /// entry rejection (the request never entered execution) or a
    /// transport-shaped failure folded to `.communicationError`. Cleared at
    /// the start of every new request.
    public private(set) var entryError: SyncError?
    /// The credential kind the most recent mutation presented — the PUK for an
    /// unblock, the SIGN PIN for a key activation — so a count-bearing outcome
    /// names the right credential (KDE `m_pendingPresentedKind`).
    public private(set) var presentedKind: CredentialKind = .unknown

    // MARK: - Backing state

    private let client: AgentCredentialsClient

    /// Cards whose sections quiescence emptied, pending a re-list. The
    /// window observes a stable card set across a quiesce/resume cycle (the
    /// same handles reappear after unlock), so recovery cannot ride a
    /// card-set change — the next registry snapshot re-lists whichever of
    /// these it still carries, and the set resets either way.
    private var quiescedCards: Set<String> = []

    /// Non-isolated holder so `deinit` can cancel the stream-consumer tasks
    /// without crossing the actor boundary (the `CardMonitor` pattern).
    private final class TaskHolder: @unchecked Sendable {
        var tasks: [Task<Void, Never>] = []
    }
    private let taskHolder = TaskHolder()

    public init(client: AgentCredentialsClient) {
        self.client = client
        // Capture the Sendable streams before the Task closures so `self`
        // (MainActor-isolated) is not pulled into the stream access itself.
        let registryUpdates = client.registryUpdates
        let quiescence = client.quiescence

        // Created in a `@MainActor` context, so both tasks inherit MainActor
        // isolation: the stream `await`s suspend without blocking the main
        // thread and the handlers are same-actor synchronous mutations.
        taskHolder.tasks.append(Task { [weak self] in
            for await snapshot in registryUpdates {
                guard let self else { return }
                self.apply(snapshot: snapshot)
            }
        })
        taskHolder.tasks.append(Task { [weak self] in
            for await _ in quiescence {
                guard let self else { return }
                self.clearAllSections()
            }
        })
    }

    deinit {
        for task in taskHolder.tasks {
            task.cancel()
        }
    }

    // MARK: - Listing

    /// Lists `card`'s credentials and (re)renders its section. A failure
    /// surfaces on `entryError`; the previously rendered section is left in
    /// place so a transient failure does not blank an existing listing.
    public func refresh(card: String) async {
        entryError = nil
        let operation: AgentOperation
        do {
            operation = try await client.listCredentials(card: card)
        } catch {
            entryError = Self.syncError(from: error)
            return
        }
        let (status, _, _, _) = await operation.finished()
        guard status == .ok, let payload = operation.credentialsResult else {
            Logger.card.error(
                "credentials listing did not complete for \(card, privacy: .public)")
            entryError = .communicationError
            return
        }
        if let index = cards.firstIndex(where: { $0.card == card }) {
            cards[index] = CredentialsCardSection(card: card, records: payload.records)
        } else {
            cards.append(CredentialsCardSection(card: card, records: payload.records))
        }
    }

    // MARK: - Mutation (change is the one verb this view model drives)

    /// Changes `pinId` on `card`. The agent collects the current and new
    /// PIN in its own secure dialog — this method only names the record and
    /// reads back the typed outcome (pull model: `credentialsResult` after
    /// `finished()`, which a failed attempt still populates). Any attempt
    /// that entered execution re-lists the card so retry counters and
    /// states re-render fresh — even one that terminalized without a typed
    /// result, since a mid-flight change may still have applied card-side;
    /// an entry error means nothing changed, so nothing is re-listed.
    public func change(card: String, pinId: String) async {
        await drive(card: card, presented: kind(ofPin: pinId, in: card)) {
            try await self.client.managePin(
                card: card, pinId: pinId, verb: .change, activateKey: false)
        }
    }

    public func unblock(card: String, pinId: String) async {
        await drive(card: card, presented: .puk) {
            try await self.client.managePin(
                card: card, pinId: pinId, verb: .unblock, activateKey: false)
        }
    }

    public func activate(card: String, pinId: String) async {
        // Bring the on-card signing key up in the same flow when it is pending,
        // so the spent transport value is not requested twice (KDE parity).
        let activateKey = record(card: card, pinId: pinId)?.keyActivationPending ?? false
        await drive(card: card, presented: kind(ofPin: pinId, in: card)) {
            try await self.client.managePin(
                card: card, pinId: pinId, verb: .activatePin, activateKey: activateKey)
        }
    }

    public func activateKey(card: String) async {
        await drive(card: card, presented: .sign) {
            try await self.client.activateSigningKey(card: card)
        }
    }

    /// Shared mutation drive: launch the verb, read the typed result (a failed
    /// attempt still populates it), re-list so counters re-render. An attempt
    /// that entered execution re-lists even without a typed result (it may have
    /// applied card-side); an entry error means nothing changed.
    private func drive(
        card: String, presented: CredentialKind,
        _ launch: () async throws -> AgentOperation
    ) async {
        entryError = nil
        lastOutcome = nil
        presentedKind = presented
        let operation: AgentOperation
        do {
            operation = try await launch()
        } catch {
            entryError = Self.syncError(from: error)
            return
        }
        _ = await operation.finished()
        guard let payload = operation.credentialsResult else {
            Logger.card.error(
                "credential mutation terminalized without a result for \(card, privacy: .public)")
            await refresh(card: card)
            entryError = .communicationError
            return
        }
        lastOutcome = payload.result
        await refresh(card: card)
    }

    private func record(card: String, pinId: String) -> CredentialRecord? {
        cards.first(where: { $0.card == card })?.records.first(where: { $0.id == pinId })
    }

    private func kind(ofPin pinId: String, in card: String) -> CredentialKind {
        record(card: card, pinId: pinId)?.kind ?? .unknown
    }

    // MARK: - Clearing

    /// Drops `card`'s section (the card was removed, or the agent went
    /// quiet). Listing state only — `lastOutcome`/`entryError` describe the
    /// most recent request and are rewritten by the next one.
    public func clear(card: String) {
        cards.removeAll { $0.card == card }
    }

    // MARK: - Per-record affordances

    /// The actions `record` advertises, derived strictly from its booleans.
    public func actions(for record: CredentialRecord) -> [CredentialAction] {
        var actions: [CredentialAction] = []
        if record.canChange { actions.append(.change) }
        if record.unblockable { actions.append(.unblock) }
        if record.activatable { actions.append(.activatePin) }
        if record.keyActivatable && record.keyActivationPending { actions.append(.activateKey) }
        return actions
    }

    /// The PUK's remaining unblock budget for `card` — the count the holder
    /// spends one of on an unblock — read from the section's PUK record's
    /// usage counters. `nil` when the section has no PUK record with a usage
    /// count. NOT the addressed PIN's `unblocksLeft` (a reset counter).
    public func unblockBudget(forCard card: String) -> (usesLeft: UInt32, usesMax: UInt32?)? {
        guard
            let section = cards.first(where: { $0.card == card }),
            let puk = section.records.first(where: { $0.kind == .puk }),
            let usesLeft = puk.usesLeft
        else { return nil }
        return (usesLeft, puk.usesMax)
    }

    // MARK: - Stream handlers

    /// A snapshot that no longer carries a listed card is that card's
    /// removal — drop its section; cards still present are untouched.
    /// The first snapshot after quiescence also restores the sections it
    /// emptied: every quiesced card the snapshot still carries is re-listed
    /// (the handles are typically unchanged across an unlock, so no card-set
    /// change follows to trigger a listing anywhere else).
    private func apply(snapshot: RegistrySnapshot) {
        let present = Set(snapshot.cards.map(\.handle))
        for section in cards where !present.contains(section.card) {
            clear(card: section.card)
        }
        let recovering = quiescedCards.intersection(present)
        quiescedCards.removeAll()
        for card in recovering.sorted() {
            Task { [weak self] in
                await self?.refresh(card: card)
            }
        }
    }

    /// Quiescence quiets every card at once — no per-card event follows.
    /// The emptied cards are remembered so the next registry snapshot can
    /// restore the ones it still carries.
    private func clearAllSections() {
        quiescedCards.formUnion(cards.map(\.card))
        for section in cards {
            clear(card: section.card)
        }
    }

    // MARK: - Error folding

    /// Folds a thrown client error into the `SyncError` vocabulary the
    /// window renders: named server errors pass through as themselves, the
    /// feature gate folds to `.notSupported`, and everything
    /// transport-shaped folds to `.communicationError`.
    private static func syncError(from error: Error) -> SyncError {
        guard let clientError = error as? AgentClientError else {
            return .communicationError
        }
        switch clientError {
        case .serverError(let info):
            if case .name(let syncError) = info.code { return syncError }
            return .communicationError
        case .notSupported:
            return .notSupported
        case .notConnected, .timeout, .connectionLost, .unexpectedReply, .communicationError:
            return .communicationError
        }
    }
}

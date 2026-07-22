// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Behavioural tests for CredentialsViewModel over a mock
// `AgentCredentialsClient`. The mock hands back pre-finished
// `AgentOperation`s — building those needs the package's internal mutators
// (`publishResult` / `resolveFinished`), hence
// `@testable import LibreMacAgentClient` (the SigningCoordinatorPhaseTests
// precedent). The mock's registry / quiescence streams stand in for the
// agent's card-removal and quiesce events, so the section-clearing wiring is
// exercised through the same path the live client drives, not by calling
// `clear(card:)` by hand (the direct call gets its own small test).
//
// No secret appears anywhere in this file: the view model only ever handles
// card and record HANDLES — PIN entry lives in the agent's secure dialog.

import Foundation
import Testing

@testable import LibreMac
@testable import LibreMacAgentClient

// MARK: - Mock client

/// Mock `AgentCredentialsClient` fed by per-method FIFO queues: each call
/// dequeues either an operation to hand back or a client error to throw.
/// Calls are recorded for interaction assertions; the registry / quiescence
/// continuations let a test emit presence events directly.
final class MockCredentialsClient: AgentCredentialsClient, @unchecked Sendable {

    struct ManagePinCall: Equatable {
        let card: String
        let pinId: String
        let verb: CredentialVerb
        let activateKey: Bool
    }

    let registryUpdates: AsyncStream<RegistrySnapshot>
    let registryContinuation: AsyncStream<RegistrySnapshot>.Continuation
    let quiescence: AsyncStream<QuiesceReason>
    let quiesceContinuation: AsyncStream<QuiesceReason>.Continuation

    var supportsCredentials: Bool { true }

    private let lock = NSLock()
    private var listQueue: [Result<AgentOperation, AgentClientError>] = []
    private var managePinQueue: [Result<AgentOperation, AgentClientError>] = []
    private var listedCardsStorage: [String] = []
    private var managePinCallsStorage: [ManagePinCall] = []
    private var activateSigningKeyQueue: [Result<AgentOperation, AgentClientError>] = []
    private var activateSigningKeyCardsStorage: [String] = []

    init() {
        let (registryStream, registryContinuation) = AsyncStream<RegistrySnapshot>.makeStream()
        self.registryUpdates = registryStream
        self.registryContinuation = registryContinuation
        let (quiescenceStream, quiesceContinuation) = AsyncStream<QuiesceReason>.makeStream()
        self.quiescence = quiescenceStream
        self.quiesceContinuation = quiesceContinuation
    }

    // `NSLock.lock()`/`unlock()` are `noasync`; funnel every use through this
    // synchronous helper so the `async` methods never call them directly.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var listedCards: [String] {
        withLock { listedCardsStorage }
    }

    var managePinCalls: [ManagePinCall] {
        withLock { managePinCallsStorage }
    }

    var activateSigningKeyCards: [String] {
        withLock { activateSigningKeyCardsStorage }
    }

    func queueActivateSigningKey(_ operation: AgentOperation) {
        withLock { activateSigningKeyQueue.append(.success(operation)) }
    }

    func queueList(_ operation: AgentOperation) {
        withLock { listQueue.append(.success(operation)) }
    }

    func queueList(error: AgentClientError) {
        withLock { listQueue.append(.failure(error)) }
    }

    func queueManagePin(_ operation: AgentOperation) {
        withLock { managePinQueue.append(.success(operation)) }
    }

    func queueManagePin(error: AgentClientError) {
        withLock { managePinQueue.append(.failure(error)) }
    }

    func listCredentials(card: String) async throws -> AgentOperation {
        let next: Result<AgentOperation, AgentClientError>? = withLock {
            listedCardsStorage.append(card)
            return listQueue.isEmpty ? nil : listQueue.removeFirst()
        }
        guard let next else {
            Issue.record("listCredentials(card: \(card)) called with an empty queue")
            throw AgentClientError.unexpectedReply
        }
        return try next.get()
    }

    func managePin(
        card: String, pinId: String, verb: CredentialVerb, activateKey: Bool
    ) async throws -> AgentOperation {
        let next: Result<AgentOperation, AgentClientError>? = withLock {
            managePinCallsStorage.append(
                ManagePinCall(card: card, pinId: pinId, verb: verb, activateKey: activateKey))
            return managePinQueue.isEmpty ? nil : managePinQueue.removeFirst()
        }
        guard let next else {
            Issue.record("managePin(card: \(card), pinId: \(pinId)) called with an empty queue")
            throw AgentClientError.unexpectedReply
        }
        return try next.get()
    }

    func activateSigningKey(card: String) async throws -> AgentOperation {
        let next: Result<AgentOperation, AgentClientError>? = withLock {
            activateSigningKeyCardsStorage.append(card)
            return activateSigningKeyQueue.isEmpty ? nil : activateSigningKeyQueue.removeFirst()
        }
        guard let next else {
            Issue.record("activateSigningKey(card: \(card)) called with an empty queue")
            throw AgentClientError.unexpectedReply
        }
        return try next.get()
    }
}

// MARK: - Fixtures

/// A credential record with display-plausible defaults; the boolean
/// affordances and counters are the knobs the cases turn.
private func credentialRecord(
    id: String = "pin.user", label: String = "User PIN", kind: CredentialKind = .user,
    retriesLeft: UInt32? = 3, usesLeft: UInt32? = nil, usesMax: UInt32? = nil,
    unblocksLeft: UInt32? = nil,
    canChange: Bool = true, unblockable: Bool = false,
    activatable: Bool = false, keyActivationPending: Bool = false, keyActivatable: Bool = false
) -> CredentialRecord {
    CredentialRecord(
        id: id, label: label, kind: kind, state: .operational,
        retriesLeft: retriesLeft, retriesMax: 3, usesLeft: usesLeft, usesMax: usesMax,
        unblocksLeft: unblocksLeft, minLength: 4, maxLength: 8,
        canChange: canChange, unblockable: unblockable, unblockStyle: .unblockAndChange,
        activatable: activatable, keyActivationPending: keyActivationPending,
        keyActivatable: keyActivatable, recovery: .holderViaPuk, probeSafe: true)
}

/// An `AgentOperation` already carrying its credentials payload (when any)
/// and its terminal outcome — the pull-model shape the view model consumes:
/// `finished()` resolves immediately, `credentialsResult` is readable after
/// it even when the terminal status is not Ok.
private func finishedOperation(
    id: UInt64, kind: OperationKind, payload: CredentialsPayload?,
    status: OperationStatus = .ok, code: ErrorCode = .none
) -> AgentOperation {
    let operation = AgentOperation(id: id, kind: kind, cancelHandler: {})
    if let payload {
        operation.publishResult(.credentials(payload), fds: [])
    }
    operation.resolveFinished((status, code, nil, ""))
    return operation
}

/// A completed Ok listing carrying `records`.
private func listOperation(records: [CredentialRecord], id: UInt64 = 1) -> AgentOperation {
    finishedOperation(
        id: id, kind: .listCredentials,
        payload: CredentialsPayload(
            result: CredentialResult(outcome: .ok, blocked: false), records: records))
}

/// A completed mutation attempt (a mutation's `records` is always empty).
private func mutationOperation(
    outcome: CredentialOutcome, retriesLeft: UInt32? = nil, blocked: Bool = false,
    status: OperationStatus = .ok, code: ErrorCode = .none, id: UInt64 = 2
) -> AgentOperation {
    finishedOperation(
        id: id, kind: .managePin,
        payload: CredentialsPayload(
            result: CredentialResult(outcome: outcome, retriesLeft: retriesLeft, blocked: blocked),
            records: []),
        status: status, code: code)
}

private func cardState(handle: String) -> CardState {
    CardState(handle: handle, reader: "reader:0", caps: [.pki], preAuth: .none)
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

// MARK: - Cases

@Suite("CredentialsViewModel")
@MainActor
struct CredentialsViewModelTests {

    @Test("a listing renders that card's section from the returned records")
    func listingRendersSection() async {
        let records = [
            credentialRecord(id: "pin.user"),
            credentialRecord(id: "pin.sign", label: "Signature PIN"),
        ]
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: records))
        let viewModel = CredentialsViewModel(client: client)

        await viewModel.refresh(card: "card:0")

        #expect(client.listedCards == ["card:0"])
        #expect(viewModel.cards == [CredentialsCardSection(card: "card:0", records: records)])
        #expect(viewModel.entryError == nil)
    }

    @Test("a completed change re-lists the card automatically")
    func changeRelistsAutomatically() async {
        let before = [credentialRecord(retriesLeft: 3)]
        let after = [credentialRecord(retriesLeft: 3, unblockable: true)]
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: before))
        client.queueManagePin(mutationOperation(outcome: .ok))
        client.queueList(listOperation(records: after, id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")

        await viewModel.change(card: "card:0", pinId: "pin.user")

        #expect(
            client.managePinCalls == [
                MockCredentialsClient.ManagePinCall(
                    card: "card:0", pinId: "pin.user", verb: .change, activateKey: false)
            ])
        #expect(client.listedCards == ["card:0", "card:0"], "the second listing is the automatic re-list")
        #expect(viewModel.lastOutcome?.outcome == .ok)
        #expect(viewModel.entryError == nil)
        #expect(viewModel.cards == [CredentialsCardSection(card: "card:0", records: after)])
    }

    @Test("a failed attempt surfaces lastOutcome with retriesLeft — and still re-lists")
    func failedAttemptSurfacesOutcome() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [credentialRecord(retriesLeft: 3)]))
        // Wrong current PIN: the agent delivers the failed-attempt payload
        // BEFORE terminalizing the operation with an error — the payload is
        // retained through the non-Ok finish.
        client.queueManagePin(
            mutationOperation(
                outcome: .invalidPin, retriesLeft: 2, status: .error, code: .credentialWrong))
        client.queueList(listOperation(records: [credentialRecord(retriesLeft: 2)], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")

        await viewModel.change(card: "card:0", pinId: "pin.user")

        #expect(viewModel.lastOutcome?.outcome == .invalidPin)
        #expect(viewModel.lastOutcome?.retriesLeft == 2)
        #expect(viewModel.entryError == nil)
        #expect(client.listedCards.count == 2, "retry counters changed — the card is re-listed")
        #expect(viewModel.cards.first?.records.first?.retriesLeft == 2)
    }

    @Test("a mutation entry error surfaces entryError and does not re-list")
    func mutationEntryErrorSurfaces() async {
        let client = MockCredentialsClient()
        client.queueManagePin(error: .serverError(ErrInfo(code: .name(.unknownCredential))))
        let viewModel = CredentialsViewModel(client: client)

        await viewModel.change(card: "card:0", pinId: "pin.stale")

        #expect(viewModel.entryError == .unknownCredential)
        #expect(viewModel.lastOutcome == nil)
        #expect(client.listedCards.isEmpty, "a request that never entered execution triggers no re-list")
    }

    @Test("a listing entry error surfaces entryError and keeps the rendered section")
    func listingEntryErrorKeepsSection() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [credentialRecord()]))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")
        #expect(viewModel.cards.count == 1)

        client.queueList(error: .serverError(ErrInfo(code: .name(.unknownCard))))
        await viewModel.refresh(card: "card:0")

        #expect(viewModel.entryError == .unknownCard)
        #expect(viewModel.cards.count == 1, "a failed refresh does not blank an already-rendered listing")
    }

    @Test("a registry snapshot without the card empties that card's section")
    func cardRemovalEmptiesSection() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [credentialRecord()]))
        client.queueList(listOperation(records: [credentialRecord(id: "pin.other")], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:A")
        await viewModel.refresh(card: "card:B")
        #expect(viewModel.cards.count == 2)

        // card:A is gone; card:B survives the same snapshot untouched.
        client.registryContinuation.yield(
            RegistrySnapshot(readers: [], cards: [cardState(handle: "card:B")]))

        #expect(await waitUntil { viewModel.cards.map(\.card) == ["card:B"] })
    }

    @Test("agent quiescence empties every section")
    func quiescenceEmptiesSections() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [credentialRecord()]))
        client.queueList(listOperation(records: [credentialRecord(id: "pin.other")], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:A")
        await viewModel.refresh(card: "card:B")
        #expect(viewModel.cards.count == 2)

        client.quiesceContinuation.yield(.screenLocked)

        #expect(await waitUntil { viewModel.cards.isEmpty })
    }

    @Test("after quiescence, a snapshot still carrying the card re-lists it")
    func quiesceRecoveryRelistsOnNextSnapshot() async {
        let records = [credentialRecord()]
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: records))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")
        #expect(viewModel.cards.count == 1)

        client.quiesceContinuation.yield(.screenLocked)
        #expect(await waitUntil { viewModel.cards.isEmpty })

        // Unlock: the registry snapshot carries the SAME handle, so no
        // card-set change follows to trigger a listing anywhere else — the
        // view model itself must re-list the card it quieted.
        client.queueList(listOperation(records: records, id: 3))
        client.registryContinuation.yield(
            RegistrySnapshot(readers: [], cards: [cardState(handle: "card:0")]))

        #expect(await waitUntil {
            viewModel.cards == [CredentialsCardSection(card: "card:0", records: records)]
        })
        #expect(client.listedCards == ["card:0", "card:0"], "the second listing is the recovery")
    }

    @Test("a payload-less mutation termination still re-lists the card")
    func payloadlessTerminationRelists() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [credentialRecord()]))
        // Terminalized with no credentials payload at all (connection lost
        // mid-flight): the attempt entered execution, so the card may have
        // changed state anyway — the re-list heals the section while the
        // communication error stays surfaced for the attempt itself.
        client.queueManagePin(
            finishedOperation(id: 2, kind: .managePin, payload: nil, status: .error))
        client.queueList(listOperation(records: [credentialRecord()], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")

        await viewModel.change(card: "card:0", pinId: "pin.user")

        #expect(viewModel.entryError == .communicationError)
        #expect(viewModel.lastOutcome == nil)
        #expect(
            client.listedCards == ["card:0", "card:0"],
            "the attempt entered execution — the card is re-listed")
        #expect(viewModel.cards.count == 1)
    }

    @Test("unblock sends the unblock verb and re-lists on Unsupported")
    func unblockSendsVerbAndRelists() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [credentialRecord(unblockable: true)]))
        // Unsupported arrives as a RESULT payload even though the op finishes
        // non-Ok — the VM must read `credentialsResult`, not treat it as a throw.
        client.queueManagePin(mutationOperation(
            outcome: .unsupported, status: .error, code: .capabilityMissing))
        client.queueList(listOperation(records: [credentialRecord(unblockable: true)], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")

        await viewModel.unblock(card: "card:0", pinId: "pin.user")

        #expect(client.managePinCalls == [
            .init(card: "card:0", pinId: "pin.user", verb: .unblock, activateKey: false)])
        #expect(client.listedCards == ["card:0", "card:0"])
        #expect(viewModel.lastOutcome?.outcome == .unsupported)
        #expect(viewModel.entryError == nil)
    }

    @Test("activate carries activateKey=true only when the key is pending")
    func activatePassesKeyContinuation() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [
            credentialRecord(id: "pin.sign", label: "Signature PIN", kind: .sign,
                             activatable: true, keyActivationPending: true, keyActivatable: true)]))
        client.queueManagePin(mutationOperation(outcome: .unsupported))
        client.queueList(listOperation(records: [], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")

        await viewModel.activate(card: "card:0", pinId: "pin.sign")

        #expect(client.managePinCalls == [
            .init(card: "card:0", pinId: "pin.sign", verb: .activatePin, activateKey: true)])
    }

    @Test("activateKey drives the id-less ActivateSigningKey and attributes to SIGN")
    func activateKeyDrivesSigningKey() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [credentialRecord(keyActivationPending: true, keyActivatable: true)]))
        client.queueActivateSigningKey(mutationOperation(outcome: .unsupported))
        client.queueList(listOperation(records: [], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")

        await viewModel.activateKey(card: "card:0")

        #expect(client.activateSigningKeyCards == ["card:0"])
        #expect(viewModel.presentedKind == .sign)
    }

    @Test("a mutation records the presented kind of the addressed credential")
    func presentedKindTracksVerb() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [credentialRecord(id: "pin.puk", label: "PUK", kind: .puk, unblockable: true)]))
        client.queueManagePin(mutationOperation(outcome: .ok))
        client.queueList(listOperation(records: [], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")

        await viewModel.unblock(card: "card:0", pinId: "pin.puk")

        #expect(viewModel.presentedKind == .puk)
    }

    @Test("change records the addressed PIN's own kind as presentedKind, not a hard-coded value")
    func presentedKindReflectsAddressedPin() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [
            credentialRecord(id: "pin.sign", label: "Signature PIN", kind: .sign)]))
        client.queueManagePin(mutationOperation(outcome: .ok))
        client.queueList(listOperation(records: [], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")

        await viewModel.change(card: "card:0", pinId: "pin.sign")

        #expect(viewModel.presentedKind == .sign)
    }

    @Test("activate omits the key continuation when the key is not pending")
    func activateOmitsKeyContinuationWhenNotPending() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [
            credentialRecord(id: "pin.sign", label: "Signature PIN", kind: .sign,
                             activatable: true, keyActivationPending: false, keyActivatable: true)]))
        client.queueManagePin(mutationOperation(outcome: .unsupported))
        client.queueList(listOperation(records: [], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")

        await viewModel.activate(card: "card:0", pinId: "pin.sign")

        #expect(client.managePinCalls == [
            .init(card: "card:0", pinId: "pin.sign", verb: .activatePin, activateKey: false)])
    }

    @Test("clear(card:) drops exactly that card's section")
    func clearDropsOneSection() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [credentialRecord()]))
        client.queueList(listOperation(records: [credentialRecord(id: "pin.other")], id: 3))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:A")
        await viewModel.refresh(card: "card:B")

        viewModel.clear(card: "card:A")

        #expect(viewModel.cards.map(\.card) == ["card:B"])
    }

    @Test("actions(for:) returns exactly the boolean-advertised set")
    func actionsDeriveFromRecordBooleans() {
        let client = MockCredentialsClient()
        let viewModel = CredentialsViewModel(client: client)

        let everything = credentialRecord(
            canChange: true, unblockable: true, activatable: true,
            keyActivationPending: true, keyActivatable: true)
        #expect(viewModel.actions(for: everything) == [.change, .unblock, .activatePin, .activateKey])

        let nothing = credentialRecord(canChange: false)
        #expect(viewModel.actions(for: nothing) == [])

        let noChange = credentialRecord(
            canChange: false, unblockable: true, activatable: true,
            keyActivationPending: true, keyActivatable: true)
        #expect(
            viewModel.actions(for: noChange) == [.unblock, .activatePin, .activateKey],
            "canChange=false yields no .change even when everything else is advertised")
    }

    @Test("activate-signing-key is offered only while the key is pending")
    func activateKeyGatedOnPending() {
        let client = MockCredentialsClient()
        let viewModel = CredentialsViewModel(client: client)
        let pending = credentialRecord(keyActivationPending: true, keyActivatable: true)
        let notPending = credentialRecord(keyActivationPending: false, keyActivatable: true)
        #expect(viewModel.actions(for: pending).contains(.activateKey))
        #expect(!viewModel.actions(for: notPending).contains(.activateKey))
    }

    @Test("the unblock budget is the PUK record's usage, not the PIN's unblocksLeft")
    func unblockBudgetReadsPukUsage() async {
        let client = MockCredentialsClient()
        // The PIN carries a POPULATED `unblocksLeft` (5) distinct from the PUK's
        // `usesLeft` (8): a budget read from the wrong counter would surface 5, so
        // asserting 8 rules out reading the PIN's reset counter, not just a nil one.
        client.queueList(listOperation(records: [
            credentialRecord(id: "pin.user", unblocksLeft: 5, unblockable: true),
            credentialRecord(id: "pin.puk", label: "PUK", kind: .puk, usesLeft: 8, usesMax: 10, canChange: false),
        ]))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")

        let budget = viewModel.unblockBudget(forCard: "card:0")
        #expect(budget?.usesLeft == 8)
        #expect(budget?.usesMax == 10)
    }

    @Test("no PUK record means no unblock budget")
    func unblockBudgetNilWithoutPuk() async {
        let client = MockCredentialsClient()
        client.queueList(listOperation(records: [credentialRecord(unblockable: true)]))
        let viewModel = CredentialsViewModel(client: client)
        await viewModel.refresh(card: "card:0")
        #expect(viewModel.unblockBudget(forCard: "card:0") == nil)
    }
}

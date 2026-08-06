// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation

/// Errors an `AgentClient` call can throw. Distinct from the wire-layer
/// `FrameError`/`MessageError` — this is the client's OWN taxonomy for
/// "why did my request not get a usable reply."
public enum AgentClientError: Error, Sendable, Equatable {
    /// No connection is currently established (never connected yet, or a
    /// reconnect attempt is in progress).
    case notConnected
    /// No reply arrived within the request's timeout.
    case timeout
    /// The connection was lost while this request was outstanding.
    case connectionLost
    /// A reply arrived and decoded, but was not the shape this call
    /// expected (a client-side bug, or an agent that answered the wrong
    /// request kind).
    case unexpectedReply
    /// The agent replied with `err`.
    case serverError(ErrInfo)
    /// A locally observed communication failure (send failed, or a
    /// terminal operation stopped with no way to recover its result).
    case communicationError
    /// The connected agent's `HelloAck.features` lacks the token this call
    /// is gated on (the credential ops require `"credentials"`) — the
    /// request was never sent: an older agent fails an unknown request `t`
    /// closed and drops the whole connection, so the client gates instead
    /// of probing.
    case notSupported
}

/// A live snapshot of the reader/card registry, published on
/// `registryUpdates` after `GetState` and after every mutating event
/// (`ReaderAdded`/`ReaderRemoved`/`CardAdded`/`CardRemoved`).
public struct RegistrySnapshot: Sendable, Equatable {
    public let readers: [ReaderState]
    public let cards: [CardState]

    public init(readers: [ReaderState], cards: [CardState]) {
        self.readers = readers
        self.cards = cards
    }
}

/// Owns one persistent connection to the LibreMac agent: (re)connects with
/// capped exponential backoff, sends `Hello` first on every connection
/// (protocol-spec convention), maintains the reader/card registry,
/// correlates requests to
/// replies by `req`, and routes unsolicited events — including operation
/// lifecycle events — to the right `AgentOperation`.
///
/// ## Concurrency
/// `AgentClient` is an actor. The connection, registry, `nextRequestId`,
/// the pending-reply table, and the live-operations table are all
/// actor-isolated stored properties, mutated only from actor-isolated
/// methods; the single task that consumes `SocketConnection.frames` for
/// the life of each connection is `runSupervisor()` itself (an
/// actor-isolated async method), so every frame is handled with the
/// actor's mutual exclusion already in force — no extra locking needed
/// there. `AgentOperation` instances handed out to callers manage their
/// own thread-safety independently (see that type's doc comment).
public actor AgentClient {

    // MARK: - Default timeouts

    public static let defaultPropTimeout: TimeInterval = 3.0
    public static let defaultDiscoveryTimeout: TimeInterval = 1.0
    public static let defaultOpStallTimeout: TimeInterval = 35.0
    /// For requests the agent may hold while it asks a human. A configuration
    /// write can be gated on the device owner authenticating, and that dialog
    /// has no timeout of its own, so the three-second property timeout gives
    /// up long before the person has answered — reporting a failure for a
    /// change the agent then applies anyway. This is only a backstop against
    /// an agent that is alive and silent: a dead one fails every pending
    /// request immediately through connection loss, not through this timer.
    public static let defaultConfirmableTimeout: TimeInterval = 300.0
    public static let defaultInitialBackoff: TimeInterval = 1.0
    public static let defaultMaxBackoff: TimeInterval = 30.0

    /// The `msgKey` a live operation's `finished()` resolves with when the
    /// agent connection is lost out from under it (the death sweep).
    public static let vanishedMsgKey = "libremac_agent_vanished"

    // MARK: - Configuration (injectable for tests)

    /// Produces a fresh connection on every (re)connect attempt. The
    /// public initializer wires this to `SocketConnection.connect(path:)`;
    /// tests use the internal initializer below to substitute a
    /// `MockAgentServer`-backed `socketpair` connection instead, without
    /// widening the public surface with a test-only seam.
    private let connector: @Sendable () async throws -> SocketConnection
    private let clientVersion: String
    private let propTimeout: TimeInterval
    private let discoveryTimeout: TimeInterval
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private var currentBackoff: TimeInterval

    // MARK: - Connection state

    private var connection: SocketConnection?
    private var supervisorTask: Task<Void, Never>?
    private var nextRequestId: UInt64 = 1

    private final class PendingReplySlot {
        let continuation: CheckedContinuation<(AgentReply, [Int32]), Error>
        var timeoutTask: Task<Void, Never>?
        init(continuation: CheckedContinuation<(AgentReply, [Int32]), Error>) {
            self.continuation = continuation
        }
    }
    private var pendingReplies: [UInt64: PendingReplySlot] = [:]

    // MARK: - Live operations

    private var liveOperations: [UInt64: AgentOperation] = [:]

    // MARK: - Registry + availability

    private var readersByHandle: [String: ReaderState] = [:]
    private var cardsByHandle: [String: CardState] = [:]
    private var availableFlag = false

    private let registryContinuation: AsyncStream<RegistrySnapshot>.Continuation
    public nonisolated let registryUpdates: AsyncStream<RegistrySnapshot>

    private let availabilityContinuation: AsyncStream<Bool>.Continuation
    public nonisolated let availability: AsyncStream<Bool>

    // MARK: - Quiescence (macOS lifecycle: sleep / lock / user-switch / shutdown)

    /// Surfaces each `AgentQuiesced{reason}` event to consumers so a UI can
    /// render "present-but-quiesced" and never leave a stale card/certificate
    /// surface up while the session is suspended. A consumer clears its own
    /// quiesced latch on the next `registryUpdates` snapshot (the "next
    /// presence event" — the agent does not emit an explicit un-quiesce).
    private let quiescenceContinuation: AsyncStream<QuiesceReason>.Continuation
    public nonisolated let quiescence: AsyncStream<QuiesceReason>

    // MARK: - Configuration changes

    /// Surfaces the name of each configuration key the agent reports as
    /// changed, so an open settings surface refreshes instead of displaying a
    /// value that is no longer true. The change may come from another client,
    /// a hand-edited configuration file, or the agent's own bookkeeping, so
    /// this is the only signal a client gets that its snapshot went stale.
    private let configChangesContinuation: AsyncStream<String>.Continuation
    public nonisolated let configChanges: AsyncStream<String>

    // MARK: - Capability display (Hello/HelloAck)

    private var agentVersion: String?
    private var agentFeatures: [String] = []

    // MARK: - Construction

    public init(
        socketPath: String = AgentSocketPath.resolve(),
        clientVersion: String = "LibreMac/unknown",
        propTimeout: TimeInterval = AgentClient.defaultPropTimeout,
        discoveryTimeout: TimeInterval = AgentClient.defaultDiscoveryTimeout,
        initialBackoff: TimeInterval = AgentClient.defaultInitialBackoff,
        maxBackoff: TimeInterval = AgentClient.defaultMaxBackoff
    ) {
        self.init(
            connector: { try SocketConnection.connect(path: socketPath) },
            clientVersion: clientVersion,
            propTimeout: propTimeout,
            discoveryTimeout: discoveryTimeout,
            initialBackoff: initialBackoff,
            maxBackoff: maxBackoff)
    }

    /// Test-only seam (see `connector`'s doc comment) — internal, reached
    /// via `@testable import`.
    init(
        connector: @escaping @Sendable () async throws -> SocketConnection,
        clientVersion: String,
        propTimeout: TimeInterval,
        discoveryTimeout: TimeInterval,
        initialBackoff: TimeInterval,
        maxBackoff: TimeInterval
    ) {
        self.connector = connector
        self.clientVersion = clientVersion
        self.propTimeout = propTimeout
        self.discoveryTimeout = discoveryTimeout
        self.initialBackoff = initialBackoff
        self.currentBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        let (registryStream, registryContinuation) = AsyncStream<RegistrySnapshot>.makeStream()
        self.registryUpdates = registryStream
        self.registryContinuation = registryContinuation
        let (availabilityStream, availabilityContinuation) = AsyncStream<Bool>.makeStream()
        self.availability = availabilityStream
        self.availabilityContinuation = availabilityContinuation
        let (quiescenceStream, quiescenceContinuation) = AsyncStream<QuiesceReason>.makeStream()
        self.quiescence = quiescenceStream
        self.quiescenceContinuation = quiescenceContinuation
        let (configStream, configContinuation) = AsyncStream<String>.makeStream()
        self.configChanges = configStream
        self.configChangesContinuation = configContinuation
    }

    deinit {
        supervisorTask?.cancel()
        registryContinuation.finish()
        availabilityContinuation.finish()
        quiescenceContinuation.finish()
        configChangesContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts the connection supervisor (connect, Hello, GetState, then
    /// consume frames until the connection is lost; repeat with capped
    /// exponential backoff). Idempotent — a second call while already
    /// running is a no-op.
    public func start() {
        guard supervisorTask == nil else { return }
        supervisorTask = Task { [weak self] in
            await self?.runSupervisor()
        }
    }

    /// Stops the supervisor and closes the connection, if any. Live
    /// operations are terminalized and the registry/availability are
    /// cleared exactly as on an involuntary connection loss.
    public func stop() {
        supervisorTask?.cancel()
        supervisorTask = nil
        connection?.close()
        connection = nil
        handleConnectionLost()
    }

    // MARK: - Supervisor loop

    private func runSupervisor() async {
        while !Task.isCancelled {
            do {
                let conn = try await connector()
                connection = conn
                // The frame pump must be running BEFORE the handshake is
                // awaited: the HelloAck/state replies arrive through the
                // same frames stream as everything else, and awaiting a
                // reply that only the not-yet-started loop could deliver
                // would deadlock every connection at Hello. This task is
                // also the connection's SINGLE frames consumer for its
                // whole life (the stream buffers unboundedly otherwise).
                // Each frame hops onto the actor via `await self.handle`,
                // one at a time, so frames are processed strictly in wire
                // order under the actor's mutual exclusion.
                let pump = Task { [weak self] in
                    do {
                        for try await frame in conn.frames {
                            guard let self else { return }
                            await self.handle(frame: frame)
                        }
                    } catch {
                        // Stream ended for a protocol/IO reason; the
                        // supervisor below runs the sweep either way.
                    }
                }
                do {
                    try await performHello(on: conn)
                    try await performGetState(on: conn)
                } catch {
                    // Handshake failure: close (which finishes the frames
                    // stream and thereby ends the pump), then re-throw
                    // into the outer cleanup path.
                    conn.close()
                    await pump.value
                    throw error
                }
                currentBackoff = initialBackoff
                availableFlag = true
                availabilityContinuation.yield(true)
                // Suspend until the connection ends (peer close, IO error,
                // or a local close via stop()); the actor stays free to
                // serve calls and process frames meanwhile. Draining the
                // pump before the sweep also guarantees no frame handling
                // interleaves with (or races after) the death sweep.
                await pump.value
            } catch {
                // Connect failure or handshake failure — same cleanup.
            }
            connection?.close()
            connection = nil
            handleConnectionLost()
            if Task.isCancelled { return }
            let wait = currentBackoff
            currentBackoff = min(currentBackoff * 2, maxBackoff)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    private func performHello(on connection: SocketConnection) async throws {
        let (reply, fds) = try await callExpectingSuccess(
            .hello(proto: UInt64(kProtocolVersion), client: clientVersion), on: connection, timeout: discoveryTimeout)
        closeFds(fds)
        guard case .helloAck(let version, let features) = reply else { throw AgentClientError.unexpectedReply }
        agentVersion = version
        agentFeatures = features
    }

    /// Checks the reply's shape only. The registry is deliberately NOT seeded
    /// here — `resolvePendingReply` seeds it as the `State` frame is
    /// dispatched, so that the snapshot and the events around it apply in wire
    /// order. See the note there.
    private func performGetState(on connection: SocketConnection) async throws {
        let (reply, fds) = try await callExpectingSuccess(.getState, on: connection)
        closeFds(fds)
        guard case .state = reply else { throw AgentClientError.unexpectedReply }
    }

    // MARK: - Death sweep (whole-tree drop; the step ordering is the contract)

    /// On connection loss: FIRST terminalize every live operation, THEN
    /// clear the registry, THEN publish `available == false`. Also fails
    /// any bare (non-operation) request still awaiting a reply — that part
    /// is unordered with respect to the three contractual steps above.
    private func handleConnectionLost() {
        let vanished = liveOperations
        liveOperations.removeAll()
        for (_, operation) in vanished {
            operation.resolveFinished((.cancelled, .communicationError, Self.vanishedMsgKey, "the agent connection was lost"))
        }

        let registryWasPopulated = !readersByHandle.isEmpty || !cardsByHandle.isEmpty
        readersByHandle.removeAll()
        cardsByHandle.removeAll()
        if registryWasPopulated {
            publishRegistrySnapshot()
        }

        if availableFlag {
            availableFlag = false
            availabilityContinuation.yield(false)
        }

        let stalePending = pendingReplies
        pendingReplies.removeAll()
        for (_, slot) in stalePending {
            slot.timeoutTask?.cancel()
            slot.continuation.resume(throwing: AgentClientError.connectionLost)
        }
    }

    /// Replaces the registry with the authoritative `State` snapshot. Called
    /// only from the frame-dispatch path, so it is ordered against every event
    /// apply by the wire.
    private func seedRegistry(readers: [ReaderState], cards: [CardState]) {
        readersByHandle = Dictionary(uniqueKeysWithValues: readers.map { ($0.handle, $0) })
        cardsByHandle = Dictionary(uniqueKeysWithValues: cards.map { ($0.handle, $0) })
        publishRegistrySnapshot()
    }

    private func publishRegistrySnapshot() {
        registryContinuation.yield(RegistrySnapshot(readers: Array(readersByHandle.values), cards: Array(cardsByHandle.values)))
    }

    // MARK: - Frame dispatch

    private func handle(frame: Frame) {
        if let envelope = try? AgentMessages.decodeReply(frame.body) {
            resolvePendingReply(envelope.req, with: envelope.reply, fds: frame.fds)
            return
        }
        if let event = try? AgentMessages.decodeEvent(frame.body) {
            handleEvent(event, fds: frame.fds)
            return
        }
        // Neither a recognized reply nor a recognized event: drop the
        // frame (and any fds it carried) rather than crash the connection
        // over a message we don't understand yet (append-only evolution —
        // new event/reply kinds are expected over time).
        closeFds(frame.fds)
    }

    private func handleEvent(_ event: AgentEvent, fds: [Int32]) {
        switch event {
        case .readerAdded(let reader):
            closeFds(fds)
            readersByHandle[reader.handle] = reader
            publishRegistrySnapshot()
        case .readerRemoved(let handle):
            closeFds(fds)
            readersByHandle.removeValue(forKey: handle)
            publishRegistrySnapshot()
        case .cardAdded(let card):
            closeFds(fds)
            cardsByHandle[card.handle] = card
            publishRegistrySnapshot()
        case .cardRemoved(let handle):
            closeFds(fds)
            cardsByHandle.removeValue(forKey: handle)
            publishRegistrySnapshot()
        case .propertyChanged:
            closeFds(fds)
        case .configChanged(let key):
            closeFds(fds)
            configChangesContinuation.yield(key)
        case .agentQuiesced(let reason):
            closeFds(fds)
            quiescenceContinuation.yield(reason)
        case .opProgress(let op, let phase, let progress, _, _):
            closeFds(fds)
            liveOperations[op]?.publishPhase(phase, progress: progress)
        case .opResultReady(let op, let result):
            guard let operation = liveOperations[op] else {
                closeFds(fds)
                return
            }
            operation.publishResult(result, fds: fds)
        case .opFinished(let op, let status, let code, let msgKey, let msgFallback):
            closeFds(fds)
            handleOpFinished(op: op, status: status, code: code, msgKey: msgKey, msgFallback: msgFallback)
        }
    }

    /// `OpResultReady` is contractually delivered BEFORE `OpFinished` for
    /// the same op. An `OpFinished(ok)` with no prior result is a
    /// hole in that contract: for `Sign`, one `GetSignResult` recovery
    /// call papers over it (mirrors the C++ client's recovery path); every
    /// other kind has no recovery twin and must surface loudly rather than
    /// resolve as a silent empty success.
    private func handleOpFinished(op: UInt64, status: OperationStatus, code: ErrorCode, msgKey: String, msgFallback: String) {
        guard let operation = liveOperations.removeValue(forKey: op) else { return }

        guard status == .ok, operation.result == nil else {
            operation.resolveFinished((status, code, msgKey.isEmpty ? nil : msgKey, msgFallback))
            return
        }

        guard operation.kind == .sign else {
            operation.resolveFinished(
                (.error, .communicationError, "libremac_agent_missing_result", "the operation finished with no result"))
            return
        }

        Task { [weak self] in
            await self?.recoverSignResult(op: op, operation: operation)
        }
    }

    private func recoverSignResult(op: UInt64, operation: AgentOperation) async {
        guard let connection else {
            operation.resolveFinished(
                (.error, .communicationError, "libremac_agent_missing_result", "sign result recovery failed: not connected"))
            return
        }
        do {
            let (reply, fds) = try await callExpectingSuccess(.getSignResult(op: op), on: connection)
            guard case .signRecovery(let result) = reply else {
                closeFds(fds)
                operation.resolveFinished(
                    (.error, .communicationError, nil, "sign result recovery returned an unexpected reply"))
                return
            }
            operation.publishResult(.sign(result), fds: fds)
            operation.resolveFinished((.ok, .none, nil, "signed"))
        } catch {
            operation.resolveFinished((.error, .communicationError, nil, "sign result recovery failed"))
        }
    }

    // MARK: - Request/reply plumbing

    private func failPendingReply(_ reqId: UInt64, with error: Error) {
        guard let slot = pendingReplies.removeValue(forKey: reqId) else { return }
        slot.timeoutTask?.cancel()
        slot.continuation.resume(throwing: error)
    }

    private func resolvePendingReply(_ reqId: UInt64, with reply: AgentReply, fds: [Int32]) {
        guard let slot = pendingReplies.removeValue(forKey: reqId) else {
            // A reply for a request we've already given up on (timeout, or
            // the connection that carried it is gone) — drop it.
            closeFds(fds)
            return
        }
        // A `State` snapshot IS a registry mutation, so it is applied here,
        // where the frame is dispatched, alongside every event apply — and
        // therefore in wire order. Applying it where the awaiting task resumes
        // instead would apply it whenever the actor next admits that task, and
        // an actor promises no ordering between a resumed task and the frame
        // pump; events that arrived after this snapshot on the wire could
        // already be in the registry, and the assignment would discard them.
        if case .state(let readers, let cards) = reply {
            seedRegistry(readers: readers, cards: cards)
        }
        slot.timeoutTask?.cancel()
        slot.continuation.resume(returning: (reply, fds))
    }

    private func call(
        _ request: AgentRequest, on connection: SocketConnection, fds: [Int32] = [], timeout: TimeInterval? = nil
    ) async throws -> (AgentReply, [Int32]) {
        let reqId = nextRequestId
        nextRequestId += 1
        let body = request.encode(req: reqId)
        let effectiveTimeout = timeout ?? propTimeout

        return try await withCheckedThrowingContinuation { continuation in
            let slot = PendingReplySlot(continuation: continuation)
            pendingReplies[reqId] = slot
            slot.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.failPendingReply(reqId, with: AgentClientError.timeout)
            }
            do {
                try connection.send(body: body, fds: fds)
            } catch {
                closeFds(fds)
                failPendingReply(reqId, with: AgentClientError.communicationError)
            }
        }
    }

    private func callExpectingSuccess(
        _ request: AgentRequest, on connection: SocketConnection, fds: [Int32] = [], timeout: TimeInterval? = nil
    ) async throws -> (AgentReply, [Int32]) {
        let (reply, replyFds) = try await call(request, on: connection, fds: fds, timeout: timeout)
        if case .err(let info) = reply {
            closeFds(replyFds)
            throw AgentClientError.serverError(info)
        }
        return (reply, replyFds)
    }

    private func closeFds(_ fds: [Int32]) {
        for fd in fds where fd >= 0 {
            Darwin.close(fd)
        }
    }

    // MARK: - Registry + capability queries

    public func readers() -> [ReaderState] {
        Array(readersByHandle.values)
    }

    public func cards() -> [CardState] {
        Array(cardsByHandle.values)
    }

    public func isAvailable() -> Bool {
        availableFlag
    }

    /// `(agentVersion, features)` as reported by the most recent
    /// `HelloAck` — for capability display; the one gated surface (the
    /// credential ops) goes through `supportsCredentials` instead.
    public func agentInfo() -> (version: String?, features: [String]) {
        (agentVersion, agentFeatures)
    }

    /// Whether the most recent `HelloAck.features` advertises the
    /// `"credentials"` token — the gate for `listCredentials` /
    /// `managePin` / `activateSigningKey`.
    public var supportsCredentials: Bool {
        agentFeatures.contains("credentials")
    }

    // MARK: - High-level API — operations

    private func registerOperation(op: UInt64, kind: OperationKind) -> AgentOperation {
        let operation = AgentOperation(id: op, kind: kind) { [weak self] in
            _ = try? await self?.cancel(op: op)
        }
        liveOperations[op] = operation
        operation.publishPhase(.created, progress: nil)
        return operation
    }

    private func startOperation(_ request: AgentRequest, kind: OperationKind) async throws -> AgentOperation {
        guard let connection else { throw AgentClientError.notConnected }
        let (reply, fds) = try await callExpectingSuccess(request, on: connection)
        closeFds(fds)
        guard case .opStarted(let op) = reply else { throw AgentClientError.unexpectedReply }
        return registerOperation(op: op, kind: kind)
    }

    public func readIdentity(card: String) async throws -> AgentOperation {
        try await startOperation(.readIdentity(card: card), kind: .readIdentity)
    }

    public func getPhoto(card: String) async throws -> AgentOperation {
        try await startOperation(.getPhoto(card: card), kind: .getPhoto)
    }

    public func readCertificates(card: String) async throws -> AgentOperation {
        try await startOperation(.readCertificates(card: card), kind: .readCertificates)
    }

    /// Starts a `Sign` operation. `input`'s fd rides the request frame's
    /// SCM_RIGHTS payload at index 0 (the wire body's `in` field) — a
    /// DUPLICATE of the fd is sent, so `input` remains fully owned by the
    /// caller (closable, reusable) both before and after this call
    /// returns, matching normal `FileHandle`-passing expectations rather
    /// than `SocketConnection.send(body:fds:)`'s "takes ownership" rule.
    public func sign(card: String, certId: String, input: FileHandle, options: SignOptions) async throws -> AgentOperation {
        guard let connection else { throw AgentClientError.notConnected }
        let duplicated = Darwin.dup(input.fileDescriptor)
        guard duplicated >= 0 else { throw AgentClientError.communicationError }
        let request = AgentRequest.sign(card: card, cert: certId, inFd: 0, opts: options)
        let (reply, fds) = try await callExpectingSuccess(request, on: connection, fds: [duplicated])
        closeFds(fds)
        guard case .opStarted(let op) = reply else { throw AgentClientError.unexpectedReply }
        return registerOperation(op: op, kind: .sign)
    }

    /// Starts a `ListCredentials` operation (the credential listing for
    /// one card). Gated on `supportsCredentials` — see
    /// `requireCredentialsSupport()`.
    public func listCredentials(card: String) async throws -> AgentOperation {
        guard connection != nil else { throw AgentClientError.notConnected }
        try requireCredentialsSupport()
        return try await startOperation(.listCredentials(card: card), kind: .listCredentials)
    }

    /// Starts a `ManagePin` operation on `pinId` (a record id from the
    /// most recent listing of `card` — this wire never carries a secret).
    /// `activateKey` is meaningful only with verb `.activatePin` and stays
    /// off the wire for every other verb (`AgentRequest.encode(req:)`).
    /// Gated on `supportsCredentials`.
    public func managePin(
        card: String, pinId: String, verb: CredentialVerb, activateKey: Bool = false
    ) async throws -> AgentOperation {
        guard connection != nil else { throw AgentClientError.notConnected }
        try requireCredentialsSupport()
        return try await startOperation(
            .managePin(card: card, pinId: pinId, verb: verb, activateKey: activateKey), kind: .managePin)
    }

    /// Starts an `ActivateSigningKey` operation (standalone signing-key
    /// bring-up continuation). Gated on `supportsCredentials`.
    public func activateSigningKey(card: String) async throws -> AgentOperation {
        guard connection != nil else { throw AgentClientError.notConnected }
        try requireCredentialsSupport()
        return try await startOperation(.activateSigningKey(card: card), kind: .activateSigningKey)
    }

    /// The client-side feature gate for the three credential ops: an agent
    /// that predates the credentials contract fails an unknown request `t`
    /// closed and DROPS the connection, so the client must never send —
    /// throw `.notSupported` before anything reaches the wire. Callers
    /// check the connection first (`agentFeatures` is only meaningful
    /// after a handshake), so a disconnected client reports
    /// `.notConnected` rather than "agent too old".
    private func requireCredentialsSupport() throws {
        guard supportsCredentials else { throw AgentClientError.notSupported }
    }

    public func cancel(op: UInt64) async throws {
        guard let connection else { throw AgentClientError.notConnected }
        let (_, fds) = try await callExpectingSuccess(.cancelOp(op: op), on: connection)
        closeFds(fds)
    }

    // MARK: - High-level API — direct request/reply (no Operation1 involved)

    public func certificateDer(reader: String, certId: String) async throws -> Data {
        guard let connection else { throw AgentClientError.notConnected }
        let (reply, fds) = try await callExpectingSuccess(.getCertDer(reader: reader, cert: certId), on: connection)
        closeFds(fds)
        guard case .certDer(let der) = reply else { throw AgentClientError.unexpectedReply }
        return der
    }

    public func getConfig() async throws -> [String: CBORValue] {
        guard let connection else { throw AgentClientError.notConnected }
        let (reply, fds) = try await callExpectingSuccess(.getConfig, on: connection)
        closeFds(fds)
        guard case .config(let entries) = reply else { throw AgentClientError.unexpectedReply }
        return entries
    }

    /// Writes one key. The agent is the authority on what it will accept: a
    /// value this method sends happily can still come back refused, and that
    /// refusal surfaces as `serverError` carrying the agent's own reason
    /// rather than being reinterpreted here.
    public func setConfig(_ key: SettableConfigKey, value: CBORValue) async throws {
        guard let connection else { throw AgentClientError.notConnected }
        let (_, fds) = try await callExpectingSuccess(
            .setConfig(key: key, value: value), on: connection,
            timeout: AgentClient.defaultConfirmableTimeout)
        closeFds(fds)
    }

    /// Restores one key to the agent's built-in default. The wire case carries
    /// an untyped key while its `SetConfig` sibling is typed; this method takes
    /// the typed key and converts, so no caller in this package can name a key
    /// the agent has never heard of.
    public func resetConfig(_ key: SettableConfigKey) async throws {
        guard let connection else { throw AgentClientError.notConnected }
        let (_, fds) = try await callExpectingSuccess(
            .resetConfig(key: key.rawValue), on: connection,
            timeout: AgentClient.defaultConfirmableTimeout)
        closeFds(fds)
    }
}

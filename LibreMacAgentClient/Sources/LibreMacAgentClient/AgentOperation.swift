// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation
import Synchronization

/// What an `AgentOperation` was started to do. Used internally by
/// `AgentClient` to decide whether an `OpFinished(ok)` with no prior
/// `OpResultReady` is recoverable (`.sign`, via `GetSignResult`) or must
/// surface loudly (every other kind has no recovery twin on the wire).
public enum OperationKind: Sendable, Equatable {
    case readIdentity
    case getPhoto
    case readCertificates
    case sign
    case listCredentials
    case managePin
    case activateSigningKey
}

/// A live (or just-finished) `Operation1` handle. Mutable state
/// (`phases` delivery, the typed result, the terminal outcome) is written
/// ONLY by `AgentClient`, on its actor — the setters below are internal and
/// called exclusively from `AgentClient`'s isolated context. Consumers
/// (any task, any thread) only ever call the public, read-only surface:
/// `phases` (an independently thread-safe `AsyncStream`), `finished()`,
/// the typed result accessors, and `cancel()`. A `Mutex` guards the handful
/// of fields those two sides share (`finished` value/waiters, the latest
/// result and its fds) — the same "confine the writer, protect the reader"
/// shape `SocketConnection` uses with its private queue.
public final class AgentOperation: Sendable {

    /// The terminal `(status, code, msgKey, msgFallback)` outcome.
    public typealias Outcome = (OperationStatus, ErrorCode, String?, String)

    public let id: UInt64
    public let kind: OperationKind

    private struct State {
        var finishedValue: Outcome?
        var finishedWaiters: [CheckedContinuation<Outcome, Never>] = []
        var latestResult: OpResult?
        var resultFds: [Int32] = []
    }
    private let state = Mutex(State())

    private let phaseContinuation: AsyncStream<(OperationPhase, Double?)>.Continuation

    /// Progress phases in wire order, terminating (no error) once
    /// `finished()`'s value has been resolved.
    public let phases: AsyncStream<(OperationPhase, Double?)>

    private let cancelHandler: @Sendable () async -> Void

    init(id: UInt64, kind: OperationKind, cancelHandler: @escaping @Sendable () async -> Void) {
        self.id = id
        self.kind = kind
        self.cancelHandler = cancelHandler
        let (stream, continuation) = AsyncStream<(OperationPhase, Double?)>.makeStream()
        self.phases = stream
        self.phaseContinuation = continuation
    }

    deinit {
        for fd in state.withLock({ $0.resultFds }) where fd >= 0 {
            Darwin.close(fd)
        }
    }

    // MARK: - Mutators (AgentClient-actor-confined — see the type doc comment)

    func publishPhase(_ phase: OperationPhase, progress: Double?) {
        phaseContinuation.yield((phase, progress))
    }

    /// Records the typed payload of an `OpResultReady` (or a successful
    /// `GetSignResult` recovery reply). `fds` are the frame's SCM_RIGHTS
    /// payload, addressable by the result's own fd-index fields
    /// (`SignResult.artifact`, `PhotoItem.fd`) via `claimResultFileHandle`.
    ///
    /// Defensive: a well-behaved server sends at most one `OpResultReady`
    /// per op, so `resultFds` is normally empty here. If a misbehaving
    /// server sends a duplicate, close the previously stored (and never
    /// claimed) fds before overwriting — otherwise they leak.
    func publishResult(_ result: OpResult, fds: [Int32]) {
        let unclaimed = state.withLock { state in
            let previous = state.resultFds
            state.latestResult = result
            state.resultFds = fds
            return previous
        }
        for fd in unclaimed where fd >= 0 {
            Darwin.close(fd)
        }
    }

    /// Resolves `finished()` exactly once; a second call is a no-op (the
    /// caller — `AgentClient` — must never invoke this twice for the same
    /// operation, but this guard makes that a correctness safety net
    /// rather than a crash). Finishes `phases` (no error) as the trailing
    /// effect, so a consumer draining `phases` with `for await` sees the
    /// stream end only after (or exactly when) `finished()` becomes
    /// resolvable.
    func resolveFinished(_ value: Outcome) {
        let waiters: [CheckedContinuation<Outcome, Never>] = state.withLock { state in
            guard state.finishedValue == nil else { return [] }
            state.finishedValue = value
            let pending = state.finishedWaiters
            state.finishedWaiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume(returning: value)
        }
        phaseContinuation.finish()
    }

    // MARK: - Consumer surface

    /// Awaits the terminal `(status, code, msgKey, msgFallback)` outcome.
    /// Resolves exactly once no matter how many callers await it
    /// concurrently or how many times a single caller calls it (a second
    /// `await` on an already-finished operation returns immediately with
    /// the same value).
    public func finished() async -> Outcome {
        if let value = state.withLock({ $0.finishedValue }) {
            return value
        }
        return await withCheckedContinuation { continuation in
            let ready: Outcome? = state.withLock { state in
                if let value = state.finishedValue { return value }
                state.finishedWaiters.append(continuation)
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }

    /// The most recently delivered typed result, if any. Populated by
    /// `OpResultReady` (which the wire delivers BEFORE `OpFinished`) or by
    /// a `Sign` recovery round-trip; `nil` before either has happened.
    public var result: OpResult? {
        state.withLock { $0.latestResult }
    }

    /// Whether `finished()` has already resolved — a non-blocking probe for
    /// the ordering tests (`@testable`), which need to know
    /// "has this operation terminalized YET" without suspending.
    var isFinished: Bool {
        state.withLock { $0.finishedValue != nil }
    }

    var identityResult: IdentityResult? {
        if case .identity(let value) = result { return value }
        return nil
    }

    public var certificatesResult: [CertificateInfo]? {
        if case .certificates(let value) = result { return value }
        return nil
    }

    public var signResult: SignResult? {
        if case .sign(let value) = result { return value }
        return nil
    }

    /// Shared by all three credential ops (a mutation's `records` is always
    /// empty). Still readable after a non-Ok `finished()` — a failed
    /// attempt's payload (`retriesLeft`) arrives as an `OpResultReady`
    /// BEFORE the error terminalization and is retained through it.
    public var credentialsResult: CredentialsPayload? {
        if case .credentials(let value) = result { return value }
        return nil
    }

    /// Claims ownership of the fd delivered alongside the current result
    /// at `fdIndex` (`SignResult.artifact`, one `PhotoItem.fd`), handing it
    /// to the caller as an already-open `FileHandle`. Returns `nil` if no
    /// fd was delivered at that index, or it was already claimed. Any fd
    /// never claimed this way is closed defensively on `deinit`.
    public func claimResultFileHandle(fdIndex: UInt64) -> FileHandle? {
        let claimed: Int32? = state.withLock { state in
            guard let index = Int(exactly: fdIndex), state.resultFds.indices.contains(index) else { return nil }
            let fd = state.resultFds[index]
            guard fd >= 0 else { return nil }
            state.resultFds[index] = -1
            return fd
        }
        guard let claimed else { return nil }
        return FileHandle(fileDescriptor: claimed, closeOnDealloc: true)
    }

    /// Requests cancellation (`CancelOp{op}`). Does not itself wait for
    /// `finished()` — the operation still terminates the normal way (an
    /// `OpFinished` event, or the death sweep if the connection is lost
    /// meanwhile).
    public func cancel() async {
        await cancelHandler()
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation

/// What an `AgentOperation` was started to do. Used internally by
/// `AgentClient` to decide whether an `OpFinished(ok)` with no prior
/// `OpResultReady` is recoverable (`.sign`, via `GetSignResult`) or must
/// surface loudly (every other kind has no recovery twin on the wire).
public enum OperationKind: Sendable, Equatable {
    case readIdentity
    case getPhoto
    case readCertificates
    case sign
}

/// A live (or just-finished) `Operation1` handle. Mutable state
/// (`phases` delivery, the typed result, the terminal outcome) is written
/// ONLY by `AgentClient`, on its actor — the setters below are internal and
/// called exclusively from `AgentClient`'s isolated context. Consumers
/// (any task, any thread) only ever call the public, read-only surface:
/// `phases` (an independently thread-safe `AsyncStream`), `finished()`,
/// the typed result accessors, and `cancel()`. A private lock guards the
/// handful of fields those two sides share (`finished` value/waiters, the
/// latest result and its fds) — the same "confine the writer, protect the
/// reader" shape `SocketConnection` uses with its private queue.
public final class AgentOperation: @unchecked Sendable {

    public let id: UInt64
    public let kind: OperationKind

    private let lock = NSLock()
    private var finishedValue: (OperationStatus, ErrorCode, String?, String)?
    private var finishedWaiters: [CheckedContinuation<(OperationStatus, ErrorCode, String?, String), Never>] = []
    private var latestResult: OpResult?
    private var resultFds: [Int32] = []

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
        for fd in resultFds where fd >= 0 {
            Darwin.close(fd)
        }
    }

    /// `NSLock.lock()`/`unlock()` are `@available(*, noasync)` — every use
    /// is funneled through this synchronous helper so an `async` caller
    /// (e.g. `finished()`) never has the bare calls in its own body.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
        withLock {
            for fd in resultFds where fd >= 0 {
                Darwin.close(fd)
            }
            latestResult = result
            resultFds = fds
        }
    }

    /// Resolves `finished()` exactly once; a second call is a no-op (the
    /// caller — `AgentClient` — must never invoke this twice for the same
    /// operation, but this guard makes that a correctness safety net
    /// rather than a crash). Finishes `phases` (no error) as the trailing
    /// effect, so a consumer draining `phases` with `for await` sees the
    /// stream end only after (or exactly when) `finished()` becomes
    /// resolvable.
    func resolveFinished(_ value: (OperationStatus, ErrorCode, String?, String)) {
        let waiters: [CheckedContinuation<(OperationStatus, ErrorCode, String?, String), Never>] = withLock {
            guard finishedValue == nil else { return [] }
            finishedValue = value
            let pending = finishedWaiters
            finishedWaiters.removeAll()
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
    public func finished() async -> (OperationStatus, ErrorCode, String?, String) {
        if let value = withLock({ finishedValue }) {
            return value
        }
        return await withCheckedContinuation { continuation in
            withLock {
                if let value = finishedValue {
                    continuation.resume(returning: value)
                } else {
                    finishedWaiters.append(continuation)
                }
            }
        }
    }

    /// The most recently delivered typed result, if any. Populated by
    /// `OpResultReady` (which the wire delivers BEFORE `OpFinished`) or by
    /// a `Sign` recovery round-trip; `nil` before either has happened.
    public var result: OpResult? {
        withLock { latestResult }
    }

    /// Whether `finished()` has already resolved — a non-blocking probe,
    /// used by consumers (and the ordering tests) that need to know
    /// "has this operation terminalized YET" without suspending.
    public var isFinished: Bool {
        withLock { finishedValue != nil }
    }

    public var identityResult: IdentityResult? {
        if case .identity(let value) = result { return value }
        return nil
    }

    public var photoResult: PhotoResult? {
        if case .photo(let value) = result { return value }
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

    /// Claims ownership of the fd delivered alongside the current result
    /// at `fdIndex` (`SignResult.artifact`, one `PhotoItem.fd`), handing it
    /// to the caller as an already-open `FileHandle`. Returns `nil` if no
    /// fd was delivered at that index, or it was already claimed. Any fd
    /// never claimed this way is closed defensively on `deinit`.
    public func claimResultFileHandle(fdIndex: UInt64) -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = Int(exactly: fdIndex), resultFds.indices.contains(index) else { return nil }
        let fd = resultFds[index]
        guard fd >= 0 else { return nil }
        resultFds[index] = -1
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Requests cancellation (`CancelOp{op}`). Does not itself wait for
    /// `finished()` — the operation still terminates the normal way (an
    /// `OpFinished` event, or the death sweep if the connection is lost
    /// meanwhile).
    public func cancel() async {
        await cancelHandler()
    }
}

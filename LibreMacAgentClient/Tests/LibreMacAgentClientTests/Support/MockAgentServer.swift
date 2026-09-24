// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation
@testable import LibreMacAgentClient

/// A scriptable stand-in for the LibreMac agent's socket server, for
/// `AgentClient` tests. Vends one `SocketConnection` (over
/// `socketpair(AF_UNIX, SOCK_STREAM, 0)` — no listener needed, matching
/// `SocketConnectionTests`' own approach) per `connect()` call, decodes
/// inbound requests with the real wire codec, and lets a test script exact
/// replies/events back with the real wire codec too — this is genuine
/// wire traffic, not a stubbed-out fake.
///
/// `connect()` is the closure an `AgentClient` under test is constructed
/// with (via the package's internal `connector`-taking initializer), so
/// the client's own reconnect-supervisor loop calls it exactly the way it
/// would call `SocketConnection.connect(path:)` in production. `stop()` /
/// `restart()` simulate the agent process disappearing and coming back —
/// while stopped, `connect()` throws, exactly like a `connect()` syscall
/// against a socket nothing is listening on.
final class MockAgentServer: @unchecked Sendable {

    enum ConnectError: Error, Sendable {
        case down
    }

    private let lock = NSLock()
    private var isUp = true
    private var connection: SocketConnection?
    private var rawServeFd: Int32 = -1
    /// Serve fds severed by `dropRawConnection()`: shut down but still open,
    /// so the number cannot be reused under the serve thread that is still
    /// reading it. That thread closes the fd itself once its read returns.
    private var droppedRawFds: Set<Int32> = []

    private let requestsContinuation: AsyncStream<DecodedRequest>.Continuation
    /// Every request the currently (or most recently) connected client has
    /// sent, in arrival order, across every `connect()` this mock has ever
    /// vended — one continuous stream for the test's lifetime.
    let requests: AsyncStream<DecodedRequest>

    private var requestCounts: [String: Int] = [:]
    private var rejectedConnections = 0

    /// How many `connect(verifier:)` calls the verifier refused.
    var rejectedConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rejectedConnections
    }

    /// Scripted per-request reaction, invoked with the decoded `req` id and
    /// its wire `t` tag (`requestTag(_:)`) for every request this mock
    /// decodes — both on the `SocketConnection` path (`connect()`) and the
    /// raw-fd path (`connectedFd()`). Tests script replies/events from
    /// inside this closure via `sendReplyRaw`/`sendEventRaw` (raw-fd path)
    /// or `sendReply`/`sendEvent` (`SocketConnection` path).
    var onRequest: ((UInt64, String) -> Void)?

    init() {
        let (stream, continuation) = AsyncStream<DecodedRequest>.makeStream()
        self.requests = stream
        self.requestsContinuation = continuation
    }

    deinit {
        requestsContinuation.finish()
        closeRawServeFd()
    }

    /// The connector closure to hand an `AgentClient` under test. The client
    /// end meets `verifier` exactly where `connectUnixSocket` puts it — after
    /// the connect, before anything is wrapped or written — so a refused
    /// server here is refused the way a real one is.
    func connect(verifier: @escaping PeerVerifier) throws -> SocketConnection {
        lock.lock()
        let up = isUp
        lock.unlock()
        guard up else { throw ConnectError.down }

        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        precondition(result == 0, "socketpair failed: \(String(cString: strerror(errno)))")
        let clientFd: Int32
        do {
            clientFd = try requireVerifiedPeer(fds[1], verifier: verifier)
        } catch {
            Darwin.close(fds[0])
            lock.lock()
            rejectedConnections += 1
            lock.unlock()
            throw error
        }
        let serverSide = SocketConnection(connectedDescriptor: fds[0])
        let clientSide = SocketConnection(connectedDescriptor: clientFd)

        lock.lock()
        connection = serverSide
        lock.unlock()
        consumeRequests(on: serverSide)
        return clientSide
    }

    private func consumeRequests(on connection: SocketConnection) {
        Task { [weak self] in
            do {
                for try await frame in connection.frames {
                    for fd in frame.fds where fd >= 0 {
                        Darwin.close(fd)
                    }
                    if let decoded = try? decodeAgentRequest(frame.body) {
                        self?.recordRequest(decoded)
                        self?.requestsContinuation.yield(decoded)
                        self?.onRequest?(decoded.req, requestTag(decoded.request))
                    }
                }
            } catch {
                // The connection ended (dropped, or the client closed it).
                // A later `connect()` (reconnect) gets its own consumer.
            }
        }
    }

    /// Simulates the agent process crashing/disappearing mid-session: the
    /// current connection is severed, and — until `restart()` — any new
    /// `connect()` attempt fails, exactly like nothing being bound to the
    /// socket path.
    func stop() {
        lock.lock()
        isUp = false
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.close()
        closeRawServeFd()
    }

    /// Severs the current connection but leaves the mock accepting new
    /// ones — a narrower fault than `stop()`, for tests that only care
    /// about "the socket died," not "the agent is gone."
    func dropConnection() {
        lock.lock()
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.close()
    }

    func restart() {
        lock.lock()
        isUp = true
        lock.unlock()
    }

    private func recordRequest(_ decoded: DecodedRequest) {
        lock.lock()
        requestCounts[requestTag(decoded.request), default: 0] += 1
        lock.unlock()
    }

    /// How many requests of `tag`'s shape (`"Hello"`, `"GetSignResult"`,
    /// `"CancelOp"`, ...) this mock has received so far, across every
    /// connection it has vended.
    func count(of tag: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[tag] ?? 0
    }

    func sendReply(_ reply: AgentReply, req: UInt64) {
        let body = encodeReply(reply, req: req)
        lock.lock()
        let conn = connection
        lock.unlock()
        try? conn?.send(body: body)
    }

    func sendEvent(_ event: AgentEvent, fds: [Int32] = []) {
        let body = encodeEvent(event)
        lock.lock()
        let conn = connection
        lock.unlock()
        try? conn?.send(body: body, fds: fds)
    }

    // MARK: - Raw-fd path (for TokenAgentClient, which is not built on SocketConnection)

    /// Returns a connected client fd; the mock serves the peer end using the same
    /// wire codec as its SocketConnection path.
    func connectedFd() -> Int32 {
        var pair: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        precondition(result == 0, "socketpair failed: \(String(cString: strerror(errno)))")
        // A script may keep writing after the client closed its end; that
        // write must fail with EPIPE, not kill the test process with SIGPIPE.
        var on: Int32 = 1
        _ = setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        lock.lock()
        rawServeFd = pair[0]
        lock.unlock()
        serve(peerFd: pair[0])
        return pair[1]
    }

    /// Background read/decode/onRequest loop over `peerFd`, the mock's end
    /// of the pair vended by `connectedFd()`. Runs until `peerFd` reaches
    /// EOF or a protocol violation poisons the reassembler.
    private func serve(peerFd: Int32) {
        Thread.detachNewThread { [weak self] in
            let reassembler = FrameReassembler()
            var buffer = [UInt8](repeating: 0, count: 4096)
            serving: while true {
                let n = read(peerFd, &buffer, buffer.count)
                if n <= 0 { break }
                guard let frames = try? reassembler.pump(bytes: Data(buffer[0..<n])) else { break }
                for frame in frames {
                    guard let decoded = try? decodeAgentRequest(frame.body) else { continue }
                    self?.recordRequest(decoded)
                    self?.requestsContinuation.yield(decoded)
                    self?.onRequest?(decoded.req, requestTag(decoded.request))
                    // A script that dropped this connection ends it here: the
                    // agent never reads past the frame it closed on.
                    if self?.wasDropped(peerFd) ?? true { break serving }
                }
            }
            self?.closeIfDropped(peerFd)
        }
    }

    /// Severs the raw-fd path's current connection the way the agent closing
    /// its end does: the client's next read sees EOF and its next write fails.
    /// Safe to call from inside `onRequest`; frames the script already wrote
    /// stay readable ahead of the EOF.
    func dropRawConnection() {
        lock.lock()
        let fd = rawServeFd
        rawServeFd = -1
        if fd >= 0 { droppedRawFds.insert(fd) }
        lock.unlock()
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    private func wasDropped(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return droppedRawFds.contains(fd)
    }

    private func closeIfDropped(_ fd: Int32) {
        lock.lock()
        let dropped = droppedRawFds.remove(fd) != nil
        lock.unlock()
        if dropped { Darwin.close(fd) }
    }

    /// Frame-encodes `reply` and writes it onto the raw-fd path's serve fd
    /// (as opposed to `sendReply`, which drives the `SocketConnection`
    /// path). For scripting a `TokenAgentClient` test's server side from
    /// inside `onRequest`.
    func sendReplyRaw(_ reply: AgentReply, req: UInt64) {
        writeRawFrame(encodeReply(reply, req: req))
    }

    /// Frame-encodes `event` and writes it onto the raw-fd path's serve fd
    /// (as opposed to `sendEvent`, which drives the `SocketConnection`
    /// path).
    func sendEventRaw(_ event: AgentEvent) {
        writeRawFrame(encodeEvent(event))
    }

    private func writeRawFrame(_ body: Data) {
        lock.lock()
        let fd = rawServeFd
        lock.unlock()
        guard fd >= 0, let header = try? Frame.encodeHeader(bodyLength: body.count, fdCount: 0) else { return }
        let framed = header + body
        framed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    /// Closes the mock's end of the `connectedFd()` pair, if one was ever
    /// vended. Idempotent. Unblocks `serve(peerFd:)`'s blocking `read` loop
    /// (which then observes an error/EOF and returns, ending the detached
    /// thread) — the raw-fd path's counterpart to `conn?.close()` tearing
    /// down the `SocketConnection` path above.
    private func closeRawServeFd() {
        lock.lock()
        let fd = rawServeFd
        rawServeFd = -1
        lock.unlock()
        guard fd >= 0 else { return }
        Darwin.close(fd)
    }
}

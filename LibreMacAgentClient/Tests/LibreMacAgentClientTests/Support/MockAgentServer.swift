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

    private let requestsContinuation: AsyncStream<DecodedRequest>.Continuation
    /// Every request the currently (or most recently) connected client has
    /// sent, in arrival order, across every `connect()` this mock has ever
    /// vended — one continuous stream for the test's lifetime.
    let requests: AsyncStream<DecodedRequest>

    private var requestCounts: [String: Int] = [:]

    init() {
        let (stream, continuation) = AsyncStream<DecodedRequest>.makeStream()
        self.requests = stream
        self.requestsContinuation = continuation
    }

    deinit {
        requestsContinuation.finish()
    }

    /// The connector closure to hand an `AgentClient` under test.
    func connect() throws -> SocketConnection {
        lock.lock()
        let up = isUp
        lock.unlock()
        guard up else { throw ConnectError.down }

        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        precondition(result == 0, "socketpair failed: \(String(cString: strerror(errno)))")
        let serverSide = SocketConnection(connectedDescriptor: fds[0])
        let clientSide = SocketConnection(connectedDescriptor: fds[1])

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
}

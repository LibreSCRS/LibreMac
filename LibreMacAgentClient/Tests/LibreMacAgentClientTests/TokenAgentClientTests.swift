// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
@testable import LibreMacAgentClient

@Suite("TokenAgentClient")
struct TokenAgentClientTests {

    @Test("send returns the correlated reply and skips interleaved events")
    func sendReturnsCorrelatedReplyAndSkipsInterleavedEvents() throws {
        let server = MockAgentServer()
        server.onRequest = { req, tag in
            if tag == "Pkcs11.PublicKey" {
                server.sendEventRaw(.cardRemoved(handle: "reader/0")) // noise before the reply
                server.sendReplyRaw(.publicKey(kty: "RSA", n: Data([0xAA]), e: Data([0x01, 0x00, 0x01])), req: req)
            }
        }

        let client = TokenAgentClient(connectedFd: server.connectedFd())
        let reply = try client.send(.pkPublicKey(reader: "reader/0", cert: "certid"))

        guard case .publicKey(let kty, let n, let e) = reply else {
            Issue.record("expected .publicKey, got \(reply)")
            return
        }
        #expect(kty == "RSA")
        #expect(n == Data([0xAA]))
        #expect(e == Data([0x01, 0x00, 0x01]))
    }

    @Test("a request written to a connection the peer already closed is reported as not delivered")
    func writeToClosedPeerIsNotDelivered() {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        // Wrap first: SO_NOSIGPIPE cannot be set on an already-disconnected fd.
        let client = TokenAgentClient(connectedFd: pair[1], ioTimeout: 0.2)
        close(pair[0])
        #expect(throws: TokenTransportError.notDelivered) {
            _ = try client.send(.getState)
        }
    }

    @Test("a peer that never replies surfaces timedOut instead of hanging forever")
    func silentPeerSurfacesTimedOut() {
        let server = MockAgentServer() // no onRequest script: requests are read but never answered
        let client = TokenAgentClient(connectedFd: server.connectedFd(), ioTimeout: 0.2)
        #expect(throws: TokenTransportError.timedOut) {
            _ = try client.send(.getState)
        }
    }

    /// The deadline belongs to the request, not to each read. Until the agent
    /// can be told not to broadcast, events keep reaching this connection while
    /// an operation is stuck; if each one re-armed the read timeout, a steady
    /// trickle of them would wedge the ctkd thread forever.
    @Test("a peer that streams events but never replies still times out after one deadline")
    func eventStreamDoesNotExtendTheDeadline() {
        let server = MockAgentServer() // requests are read, never answered
        let deadline: TimeInterval = 0.5
        let client = TokenAgentClient(connectedFd: server.connectedFd(), ioTimeout: deadline)

        // Events every 0.1 s until the send returns. The pump is also capped,
        // so a client that ignores the deadline fails the elapsed-time
        // expectation below instead of hanging the suite.
        let stop = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let cap = Date().addingTimeInterval(4)
        Thread.detachNewThread {
            while Date() < cap, stop.wait(timeout: .now() + 0.1) == .timedOut {
                server.sendEventRaw(.cardRemoved(handle: "reader/0"))
            }
            stopped.signal()
        }

        let start = Date()
        #expect(throws: TokenTransportError.timedOut) { _ = try client.send(.getState) }
        let elapsed = Date().timeIntervalSince(start)
        stop.signal()
        stopped.wait()
        #expect(elapsed < 2 * deadline, "timed out after \(elapsed) s, deadline \(deadline) s")
    }

    /// A write that stops part-way leaves the start of a frame with the agent.
    /// If a later request were written on the same fd, its bytes would complete
    /// that frame into a request nobody sent. The client must write nothing
    /// more and close the fd, so the agent sees a truncated frame, then EOF.
    @Test("after a failed write the client writes nothing more and closes the connection")
    func failedWriteRetiresTheConnection() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let peer = pair[0]
        defer { close(peer) }
        var small: Int32 = 4096
        _ = setsockopt(pair[1], SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        let client = TokenAgentClient(connectedFd: pair[1], ioTimeout: 0.2)

        // The peer does not read, so the large frame stalls part-way and the
        // write deadline expires.
        let big = AgentRequest.pkSignRaw(reader: "r", cert: "c", data: Data(count: 512 * 1024))
        let frameLength = 4 + big.encode(req: 1).count
        #expect(throws: TokenTransportError.timedOut) { _ = try client.send(big) }
        #expect(throws: TokenTransportError.notDelivered) { _ = try client.send(.getState) }

        // Everything the peer can ever read is the truncated first frame. The
        // read deadline turns a connection left open into a failure, not a hang.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var received = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(peer, &buffer, buffer.count)
            if n <= 0 {
                #expect(n == 0, "expected EOF, got errno \(errno)")
                break
            }
            received += n
        }
        #expect(received > 0)
        #expect(received < frameLength)
    }
}

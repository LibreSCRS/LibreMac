// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation
import Testing
@testable import LibreMacAgentClient

// Exercises `SocketConnection` over `socketpair(AF_UNIX, SOCK_STREAM, 0)` —
// no listener needed, both ends are already "connected". Most tests wrap
// BOTH ends in a `SocketConnection` and let the two instances talk to each
// other; a few (malformed-frame injection, raw-EOF observation) write/read
// one end directly with POSIX calls to see wire-level effects the typed API
// would otherwise validate away.

@Suite("SocketConnection")
struct SocketConnectionTests {

    // MARK: - Helpers

    private func makeSocketPair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        precondition(result == 0, "socketpair failed: \(String(cString: strerror(errno)))")
        return (fds[0], fds[1])
    }

    /// A disposable, independently-closable fd to pass as ancillary data —
    /// stands in for the "signed artifact / photo" fds the real protocol
    /// passes, without depending on any real resource.
    private func openThrowawayFd() -> Int32 {
        let fd = open("/dev/null", O_RDONLY)
        precondition(fd >= 0, "open(/dev/null) failed: \(String(cString: strerror(errno)))")
        return fd
    }

    private func shrinkSendBuffer(_ fd: Int32, to size: Int32) {
        var value = size
        let result = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &value, socklen_t(MemoryLayout<Int32>.size))
        precondition(result == 0, "setsockopt(SO_SNDBUF) failed: \(String(cString: strerror(errno)))")
    }

    private func rawHeaderBytes(bodyLength: UInt32, fdCount: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(UInt8(bodyLength & 0xFF))
        bytes.append(UInt8((bodyLength >> 8) & 0xFF))
        bytes.append(UInt8((bodyLength >> 16) & 0xFF))
        bytes.append(UInt8((bodyLength >> 24) & 0xFF))
        bytes.append(UInt8(fdCount & 0xFF))
        bytes.append(UInt8((fdCount >> 8) & 0xFF))
        bytes.append(UInt8((fdCount >> 16) & 0xFF))
        bytes.append(UInt8((fdCount >> 24) & 0xFF))
        return bytes
    }

    // MARK: - fd passing + FD_CLOEXEC

    @Test("delivers a frame's fds to the receiver, each with FD_CLOEXEC set")
    func deliversFdsWithCloexec() async throws {
        let (senderFd, receiverFd) = makeSocketPair()
        let sender = SocketConnection(connectedDescriptor: senderFd)
        let receiver = SocketConnection(connectedDescriptor: receiverFd)
        defer {
            sender.close()
            receiver.close()
        }

        let passed1 = openThrowawayFd()
        let passed2 = openThrowawayFd()
        try sender.send(body: Data([0xAA, 0xBB, 0xCC]), fds: [passed1, passed2])

        var iterator = receiver.frames.makeAsyncIterator()
        let frame = try #require(await iterator.next())

        #expect(frame.body == Data([0xAA, 0xBB, 0xCC]))
        #expect(frame.fds.count == 2)
        for fd in frame.fds {
            let flags = fcntl(fd, F_GETFD)
            #expect(flags >= 0)
            #expect(flags & FD_CLOEXEC != 0)
            close(fd)
        }
    }

    // MARK: - Fail-closed on protocol violations

    @Test("an oversize inbound frame closes the connection with .oversize")
    func oversizeInboundClosesWithOversize() async throws {
        let (rawFd, wrappedFd) = makeSocketPair()
        let receiver = SocketConnection(connectedDescriptor: wrappedFd)
        defer {
            receiver.close()
            close(rawFd)
        }

        // A declared bodyLength above kMaxFrameBytes is rejected from the
        // header alone; no real oversize body needs to exist on the wire.
        let header = rawHeaderBytes(bodyLength: UInt32(kMaxFrameBytes + 1), fdCount: 0)
        header.withUnsafeBytes { raw in
            _ = write(rawFd, raw.baseAddress, raw.count)
        }

        var iterator = receiver.frames.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("expected the frame stream to throw .oversize")
        } catch {
            #expect((error as? FrameError) == .oversize)
        }
    }

    // MARK: - Peer close

    @Test("peer close surfaces .peerClosed")
    func peerCloseSurfacesPeerClosed() async throws {
        let (fdA, fdB) = makeSocketPair()
        let connA = SocketConnection(connectedDescriptor: fdA)
        let connB = SocketConnection(connectedDescriptor: fdB)
        defer { connB.close() }

        connA.close()

        var iterator = connB.frames.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("expected the frame stream to throw .peerClosed")
        } catch {
            #expect((error as? FrameError) == .peerClosed)
        }
    }

    @Test("close() causes the peer to observe a clean EOF")
    func closeCausesPeerEOF() async throws {
        let (rawFd, wrappedFd) = makeSocketPair()
        defer { close(rawFd) }
        let connection = SocketConnection(connectedDescriptor: wrappedFd)

        connection.close()

        // close() hops onto the connection's private queue asynchronously;
        // there is no async signal observable from a RAW peer fd (that is
        // exactly what this test is probing), so poll with a bounded
        // deadline rather than a fixed sleep.
        let deadline = Date().addingTimeInterval(2)
        var sawEOF = false
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 8)
            let n = buffer.withUnsafeMutableBytes { raw in
                recv(rawFd, raw.baseAddress, raw.count, MSG_DONTWAIT)
            }
            if n == 0 {
                sawEOF = true
                break
            }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try? await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            break
        }
        #expect(sawEOF)
    }

    @Test("close() is idempotent")
    func closeIsIdempotent() async throws {
        let (fdA, fdB) = makeSocketPair()
        close(fdB) // nothing on the other end; irrelevant to this test
        let connection = SocketConnection(connectedDescriptor: fdA)

        connection.close()
        connection.close() // must not crash or double-finish the stream

        var iterator = connection.frames.makeAsyncIterator()
        let result = try await iterator.next()
        #expect(result == nil) // finished cleanly: no error, no frames
    }

    // MARK: - Non-blocking writes: queuing, EAGAIN, and the partial-send/fd interaction

    @Test("queues and flushes a write across EAGAIN")
    func queuesAndFlushesOnEAGAIN() async throws {
        let (senderFd, receiverFd) = makeSocketPair()
        shrinkSendBuffer(senderFd, to: 4096)
        let sender = SocketConnection(connectedDescriptor: senderFd)
        let receiver = SocketConnection(connectedDescriptor: receiverFd)
        defer {
            sender.close()
            receiver.close()
        }

        // Comfortably larger than the shrunk SO_SNDBUF, so at least one
        // write hits EAGAIN and must be queued/retried on write-readiness.
        let body = Data(repeating: 0x5A, count: 512 * 1024)
        try sender.send(body: body)

        var iterator = receiver.frames.makeAsyncIterator()
        let frame = try #require(await iterator.next())
        #expect(frame.body == body)
        #expect(frame.fds.isEmpty)
    }

    @Test("a partial first sendmsg attaches fds exactly once — never on the retry")
    func partialSendWithFdsAttachesExactlyOnce() async throws {
        let (senderFd, receiverFd) = makeSocketPair()
        // Small enough that the FIRST sendmsg (header + start of a 512 KiB
        // body, plus the SCM_RIGHTS ancillary) cannot possibly complete in
        // one call — forcing the partial-send/retry path this test targets.
        shrinkSendBuffer(senderFd, to: 4096)
        let sender = SocketConnection(connectedDescriptor: senderFd)
        let receiver = SocketConnection(connectedDescriptor: receiverFd)
        defer {
            sender.close()
            receiver.close()
        }

        let passed1 = openThrowawayFd()
        let passed2 = openThrowawayFd()
        let body = Data(repeating: 0x7E, count: 512 * 1024)
        try sender.send(body: body, fds: [passed1, passed2])

        var iterator = receiver.frames.makeAsyncIterator()
        let frame = try #require(await iterator.next())

        #expect(frame.body == body)
        // The mandatory assertion: exactly 2 fds arrive, never 4 (fds
        // re-attached on a retry) and never 0 (fds dropped after the first
        // partial write).
        #expect(frame.fds.count == 2)
        for fd in frame.fds {
            close(fd)
        }
    }

    // MARK: - Local (synchronous) validation

    @Test("send rejects a body over kMaxFrameBytes synchronously, without touching the socket")
    func sendRejectsOversizeBodySynchronously() throws {
        let (fdA, fdB) = makeSocketPair()
        let connection = SocketConnection(connectedDescriptor: fdA)
        defer {
            connection.close()
            close(fdB)
        }
        #expect(throws: FrameError.oversize) {
            try connection.send(body: Data(count: kMaxFrameBytes + 1))
        }
    }

    @Test("send rejects more fds than kMaxFrameFds synchronously")
    func sendRejectsTooManyFdsSynchronously() throws {
        let (fdA, fdB) = makeSocketPair()
        let connection = SocketConnection(connectedDescriptor: fdA)
        let fds = (0..<(kMaxFrameFds + 1)).map { _ in openThrowawayFd() }
        defer {
            connection.close()
            close(fdB)
            for fd in fds {
                close(fd)
            }
        }
        #expect(throws: FrameError.tooManyFds) {
            try connection.send(body: Data(), fds: fds)
        }
    }

    // MARK: - connect(path:)

    @Test("connect(path:) rejects a path that does not fit sun_path, before touching the socket")
    func connectRejectsOverlongPath() {
        let overlong = String(repeating: "x", count: 200)
        #expect(throws: SocketConnectionError.pathTooLong) {
            _ = try SocketConnection.connect(path: overlong)
        }
    }

    @Test("connect(path:) fails with .connectFailed for a path nothing is listening on")
    func connectFailsForMissingListener() {
        let path = "/tmp/librescrs-agentclient-test-\(UUID().uuidString).sock"
        #expect(throws: (any Error).self) {
            _ = try SocketConnection.connect(path: path)
        }
    }
}

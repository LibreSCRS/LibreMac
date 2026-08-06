// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation

/// Blocking pk-* client. Owns one AF_UNIX connection for its lifetime, sends
/// length-prefixed CBOR frames (uint32-LE header via Frame.encodeHeader), and
/// reads frames via FrameReassembler until the reply matching the request's `req`
/// arrives. The pk-* seam passes no fds. Not Sendable; confined to the ctkd thread.
public final class TokenAgentClient: TokenTransport {
    private var fd: Int32
    private var ownsFd: Bool
    private var nextReq: UInt64 = 1
    private let reassembler = FrameReassembler()
    private var pending: [Frame] = []

    /// Upper bound on any single blocking `read`/`write` (SO_RCVTIMEO /
    /// SO_SNDTIMEO). Any inbound traffic re-arms it, so it is the
    /// blocking-seam analog of `OperationDriver.opStallTimeout`'s
    /// no-progress watchdog — but generous where that one is exempt: an
    /// operator-facing wait (PIN entry happens agent-side) sends this seam
    /// no phase events to exempt it with, so the bound must outlast a slow
    /// operator while still surfacing a hung agent as
    /// `TokenTransportError.ioFailed` instead of wedging the ctkd thread
    /// forever.
    public static let defaultIoTimeout: TimeInterval = 120.0

    /// Wraps an already-connected fd and takes ownership of it: the fd is
    /// closed on `deinit`. Also suppresses `SIGPIPE` on the fd (see
    /// `setNoSigPipe`) before any `write` can reach it, and bounds every
    /// blocking read/write with `ioTimeout` (see `defaultIoTimeout`).
    public init(connectedFd: Int32, ioTimeout: TimeInterval = TokenAgentClient.defaultIoTimeout) {
        self.fd = connectedFd
        self.ownsFd = true
        Self.setNoSigPipe(connectedFd)
        Self.setIoDeadline(connectedFd, seconds: ioTimeout)
    }

    /// Connects via the shared `connectUnixSocket(path:)` helper (the one
    /// AF_UNIX connect sequence in this package), folding every connect-time
    /// failure into `TokenTransportError.connectFailed` — this seam has no
    /// use for the finer-grained `SocketConnectionError` split.
    public convenience init(socketPath: String = AgentSocketPath.resolve()) throws {
        let fd: Int32
        do {
            fd = try connectUnixSocket(path: socketPath)
        } catch {
            throw TokenTransportError.connectFailed
        }
        self.init(connectedFd: fd)
    }

    deinit { if ownsFd, fd >= 0 { close(fd) } }

    public func send(_ request: AgentRequest) throws -> AgentReply {
        let req = nextReq
        nextReq &+= 1
        let body = request.encode(req: req)
        try writeAll(try Frame.encodeHeader(bodyLength: body.count, fdCount: 0))
        try writeAll(body)
        while true {
            let frame = try nextFrame()
            guard let env = try? AgentMessages.decodeReply(frame.body), env.req == req else {
                continue // event or non-matching reply — discard
            }
            return env.reply
        }
    }

    private func nextFrame() throws -> Frame {
        while pending.isEmpty {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            if n == 0 { throw TokenTransportError.closed }
            if n < 0 {
                if errno == EINTR { continue }
                // EAGAIN/EWOULDBLOCK here means the SO_RCVTIMEO deadline
                // expired (the fd is otherwise blocking): a hung agent
                // surfaces as ioFailed rather than wedging the ctkd thread.
                throw TokenTransportError.ioFailed
            }
            // `FrameReassembler.pump` is sticky-poisoned: once it throws, every
            // later call rethrows the same error without buffering new bytes.
            // Swallowing that error here would leave `pending` empty forever,
            // spinning the `while pending.isEmpty` loop above with no way out.
            do {
                pending.append(contentsOf: try reassembler.pump(bytes: Data(buf[0..<n])))
            } catch {
                throw TokenTransportError.decodeFailed
            }
        }
        return pending.removeFirst()
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw TokenTransportError.ioFailed
                }
                off += n
            }
        }
    }

    /// Writing to a peer-closed socket must return `EPIPE`, not raise
    /// `SIGPIPE` (whose default action would terminate the process).
    /// `SO_NOSIGPIPE` is not inherited across `connect()`/`socketpair()`, so
    /// every fd this type owns sets it individually. Mirrors
    /// `SocketConnection.setNoSigPipe`.
    private static func setNoSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Bounds every blocking `read`/`write` on `fd` (SO_RCVTIMEO /
    /// SO_SNDTIMEO): expiry returns -1 with EAGAIN/EWOULDBLOCK, which the
    /// IO loops map to `TokenTransportError.ioFailed`.
    private static func setIoDeadline(_ fd: Int32, seconds: TimeInterval) {
        let whole = Int(seconds)
        var tv = timeval(tv_sec: whole, tv_usec: Int32((seconds - TimeInterval(whole)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

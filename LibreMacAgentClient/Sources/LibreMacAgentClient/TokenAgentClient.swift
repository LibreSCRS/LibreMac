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

    /// Wraps an already-connected fd and takes ownership of it: the fd is
    /// closed on `deinit`. Also suppresses `SIGPIPE` on the fd (see
    /// `setNoSigPipe`) before any `write` can reach it.
    public init(connectedFd: Int32) {
        self.fd = connectedFd
        self.ownsFd = true
        Self.setNoSigPipe(connectedFd)
    }

    public convenience init(socketPath: String = AgentSocketPath.resolve()) throws {
        let pathBytes = Array(socketPath.utf8)
        let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard pathBytes.count < sunPathCapacity else { throw TokenTransportError.connectFailed }

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw TokenTransportError.connectFailed }
        Self.setNoSigPipe(s)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, src, 103) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) == 0 }
        }
        guard ok else { close(s); throw TokenTransportError.connectFailed }
        self.init(connectedFd: s)
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
}

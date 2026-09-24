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
    private let ioTimeout: TimeInterval

    /// Upper bound on one request, from its first written byte to its reply.
    /// It is one deadline for the whole exchange: inbound events do not
    /// extend it, since until the agent can be told not to broadcast them a
    /// steady trickle would otherwise keep a stuck request waiting forever.
    /// It is generous where `OperationDriver.opStallTimeout` is exempt: an
    /// operator-facing wait (PIN entry happens agent-side) sends this seam
    /// no phase events to exempt it with, so the bound must outlast a slow
    /// operator while still surfacing a hung agent as
    /// `TokenTransportError.timedOut` instead of wedging the ctkd thread
    /// forever. Pinned to `PromptBudget.maxSequential` plus margin, not a
    /// bare literal: a request may chain more than one prompt (CAN entry
    /// followed by a PIN change), and nothing extends it mid-chain, so it
    /// must outlive the whole chain, not just one prompt.
    public static let defaultIoTimeout: TimeInterval = PromptBudget.maxSequential + 30

    /// Wraps an already-connected fd and takes ownership of it: the fd is
    /// closed on `deinit`. Also suppresses `SIGPIPE` on the fd (see
    /// `setNoSigPipe`) before any `write` can reach it, and bounds every
    /// request with `ioTimeout` (see `defaultIoTimeout`).
    /// Internal: the fd has not met a `PeerVerifier`, so production reaches a
    /// connection only through `init(socketPath:verifier:)`.
    init(connectedFd: Int32, ioTimeout: TimeInterval = TokenAgentClient.defaultIoTimeout) {
        self.fd = connectedFd
        self.ownsFd = true
        self.ioTimeout = ioTimeout
        Self.setNoSigPipe(connectedFd)
    }

    /// Connects via the shared `connectUnixSocket(path:verifier:)` helper
    /// (the one AF_UNIX connect sequence in this package). A serving process
    /// `verifier` rejects is `TokenTransportError.peerRejected`; every other
    /// connect-time failure folds into `connectFailed` — this seam has no use
    /// for the finer-grained `SocketConnectionError` split.
    public convenience init(
        socketPath: String = AgentSocketPath.resolve(), verifier: PeerVerifier = defaultPeerVerifier()
    ) throws {
        let fd: Int32
        do {
            fd = try connectUnixSocket(path: socketPath, verifier: verifier)
        } catch .peerRejected {
            throw TokenTransportError.peerRejected
        } catch {
            throw TokenTransportError.connectFailed
        }
        self.init(connectedFd: fd)
    }

    deinit { if ownsFd, fd >= 0 { close(fd) } }

    public func send(_ request: AgentRequest) throws -> AgentReply {
        // A connection that failed once is finished. After a failed write the
        // agent may hold the start of a frame, and any later byte on this fd
        // would complete it into a request nobody sent; so nothing is written
        // again, and the fd is closed at once, which makes the agent discard
        // the partial frame.
        guard fd >= 0 else { throw TokenTransportError.notDelivered }
        do {
            return try exchange(request)
        } catch {
            retire()
            throw error
        }
    }

    private func exchange(_ request: AgentRequest) throws -> AgentReply {
        let req = nextReq
        nextReq &+= 1
        let body = request.encode(req: req)
        let deadline = ContinuousClock.now + .seconds(ioTimeout)
        // A write that fails leaves at most part of the frame with the agent,
        // which dispatches only whole frames and discards the rest when this
        // fd closes: the request was never acted on (`notDelivered`). A write
        // deadline stays `timedOut`: the agent is there but not reading.
        do {
            try writeAll(try Frame.encodeHeader(bodyLength: body.count, fdCount: 0), until: deadline)
            try writeAll(body, until: deadline)
        } catch TokenTransportError.ioFailed {
            throw TokenTransportError.notDelivered
        }
        while true {
            let frame = try nextFrame(until: deadline)
            guard let env = try? AgentMessages.decodeReply(frame.body), env.req == req else {
                continue // event or non-matching reply — discard
            }
            return env.reply
        }
    }

    private func retire() {
        if ownsFd, fd >= 0 { close(fd) }
        fd = -1
    }

    private func nextFrame(until deadline: ContinuousClock.Instant) throws -> Frame {
        while pending.isEmpty {
            try armRemaining(SO_RCVTIMEO, until: deadline)
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            if n == 0 { throw TokenTransportError.closed }
            if n < 0 {
                let failure = errno
                if failure == EINTR { continue }
                // EAGAIN/EWOULDBLOCK here means SO_RCVTIMEO, set to what is
                // left of the request's deadline, expired (the fd is otherwise
                // blocking): a hung agent surfaces as timedOut rather than
                // wedging the ctkd thread.
                if failure == EAGAIN || failure == EWOULDBLOCK { throw TokenTransportError.timedOut }
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

    private func writeAll(_ data: Data, until deadline: ContinuousClock.Instant) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                try armRemaining(SO_SNDTIMEO, until: deadline)
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n < 0 {
                    let failure = errno
                    if failure == EINTR { continue }
                    // SO_SNDTIMEO expired: the agent is alive but not reading.
                    if failure == EAGAIN || failure == EWOULDBLOCK { throw TokenTransportError.timedOut }
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

    /// The shortest timeout ever armed. A zero `timeval` would mean "no
    /// timeout" to the kernel, the opposite of a nearly spent deadline.
    static let minimumArmedTimeout: Duration = .milliseconds(1)

    /// Sets `option` (SO_RCVTIMEO or SO_SNDTIMEO) to what is left of
    /// `deadline`, so the next blocking `read`/`write` cannot outlast the
    /// request. A spent deadline is `timedOut` without touching the fd.
    /// Expiry returns -1 with EAGAIN/EWOULDBLOCK, which the IO loops map to
    /// `TokenTransportError.timedOut`.
    private func armRemaining(_ option: Int32, until deadline: ContinuousClock.Instant) throws {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw TokenTransportError.timedOut }
        let armed = max(remaining, Self.minimumArmedTimeout)
        let (seconds, attoseconds) = armed.components
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
        _ = setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation

/// Errors raised by `SocketConnection.connect(path:)` before any frame
/// traffic is possible — distinct from `FrameError`, which covers the
/// live connection's protocol/IO lifecycle.
public enum SocketConnectionError: Error, Sendable, Equatable {
    /// `path`'s UTF-8 encoding does not fit `sockaddr_un.sun_path` (104
    /// bytes on Darwin, including the NUL terminator). Rejected outright —
    /// never silently truncated.
    case pathTooLong
    /// `socket(AF_UNIX, SOCK_STREAM, 0)` failed; the raw `errno`.
    case socketCreationFailed(Int32)
    /// `connect()` failed; the raw `errno`.
    case connectFailed(Int32)
    /// Connected, but the process serving the socket is not the one the
    /// `PeerVerifier` accepts. The fd was closed with nothing written on it.
    case peerRejected
}

/// Blocking AF_UNIX `SOCK_STREAM` connect shared by `SocketConnection` and
/// `TokenAgentClient` — the ONE place the `sun_path` capacity check, the
/// `socket()`/`sockaddr_un`-fill/`connect()` sequence, the check of the
/// serving process (`verifier`, before anything is written), and the
/// close-on-failure live. Returns the connected fd still in its default
/// blocking mode with no options set: each caller configures non-blocking /
/// `SO_NOSIGPIPE` / deadlines to its own needs afterwards (a local AF_UNIX
/// `connect()` never stalls the way a network handshake can, so connecting
/// on a blocking fd is fine for both).
func connectUnixSocket(path: String, verifier: PeerVerifier) throws(SocketConnectionError) -> Int32 {
    let pathBytes = Array(path.utf8)
    let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    guard pathBytes.count < sunPathCapacity else {
        throw .pathTooLong
    }

    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw .socketCreationFailed(errno)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
        base.initialize(repeating: 0, count: sunPathCapacity)
        for (index, byte) in pathBytes.enumerated() {
            base[index] = byte
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        let failure = errno
        Darwin.close(fd)
        throw .connectFailed(failure)
    }
    return try requireVerifiedPeer(fd, verifier: verifier)
}

/// A non-blocking AF_UNIX `SOCK_STREAM` connection to the LibreMac agent,
/// framing traffic with `Frame`/`FrameReassembler` and passing fds via
/// SCM_RIGHTS. Mirrors the peer agent's dispatch_source client transport
/// (`SocketTransport.cpp`'s per-connection read/write source pair), adapted
/// to the client side of the socket.
///
/// ## Concurrency
/// `SocketConnection` is `@unchecked Sendable`. Every mutable stored
/// property (`fileDescriptor`, `readSource`, `writeSource`, `reassembler`,
/// `outbox`, `isClosed`) is touched ONLY from `queue`, a private serial
/// `DispatchQueue`: `send(body:fds:)` and `close()` hop onto `queue` before
/// touching state, and the `DispatchSourceRead`/`DispatchSourceWrite` event
/// handlers already run on `queue` because that is the queue they were
/// created against. No two threads ever race on this state — that
/// confinement, not a lock, is what makes the `@unchecked` conformance
/// sound. `frames` (an `AsyncThrowingStream`) and its `Continuation` are
/// independently thread-safe and need no additional guard.
///
/// ## fd ownership
/// - Outbound: `send(body:fds:)` takes ownership of `fds` ONLY when it
///   returns normally; on a throw, ownership stays with the caller (see
///   its doc comment). Once owned, they are duplicated into the peer via
///   the frame's first `sendmsg` and closed locally once the whole frame
///   has been written (or when the connection tears down with the frame
///   still queued) — never closed early, so a frame killed mid-write
///   cannot outlive the descriptors it was still using.
/// - Inbound: fds delivered on a `Frame` from `frames` become the
///   consumer's responsibility to close. `SocketConnection` itself only
///   closes fds that were received but never attributed to a completed
///   frame (via `FrameReassembler.drainUnattributedFds()`), on teardown.
public final class SocketConnection: @unchecked Sendable {

    private struct PendingFrame {
        var bytes: [UInt8]
        var offset: Int = 0
        var fds: [Int32]
        var fdsAttached: Bool = false
    }

    private enum ReadOutcome {
        case data(bytes: [UInt8], fds: [Int32])
        case wouldBlock
        /// `recvmsg` was interrupted by a signal (EINTR) — retry, exactly
        /// as the send path retries an EINTR from `sendmsg`/`write`. Never
        /// a teardown reason.
        case interrupted
        case eof
        case ioError(Int32)
    }

    private enum SendOutcome {
        case sent
        case wouldBlock
        case ioError(Int32)
    }

    // MARK: - State confined to `queue` (see the type doc comment)

    private let queue: DispatchQueue
    private var fileDescriptor: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private let reassembler = FrameReassembler()
    private var outbox: [PendingFrame] = []
    private var isClosed = false

    private let continuation: AsyncThrowingStream<Frame, Error>.Continuation

    /// Frames delivered in wire order. Terminates by throwing a
    /// `FrameError` when the connection ends for a protocol/IO reason
    /// (`.peerClosed`, `.oversize`, `.tooManyFds`, `.fdMismatch`, `.io`), or
    /// finishes cleanly (no error) when `close()` was called locally.
    public let frames: AsyncThrowingStream<Frame, Error>

    // MARK: - Construction

    /// Opens a non-blocking AF_UNIX `SOCK_STREAM` connection to `path`
    /// (via `connectUnixSocket(path:verifier:)`), refusing a serving process
    /// `verifier` rejects; the fd is switched to non-blocking once connected
    /// and verified, before any frame traffic is possible.
    public static func connect(
        path: String, verifier: PeerVerifier = defaultPeerVerifier()
    ) throws(SocketConnectionError) -> SocketConnection {
        SocketConnection(connectedDescriptor: try connectUnixSocket(path: path, verifier: verifier))
    }

    /// Wraps an already-connected fd. Internal (not part of the public
    /// surface) — production callers go through `connect(path:)`; tests use
    /// this to attach both ends of a `socketpair(AF_UNIX, SOCK_STREAM, 0)`
    /// without needing a listener. Takes ownership of `fd`: configures it
    /// non-blocking + close-on-exec + `SO_NOSIGPIPE` and installs the read
    /// source immediately.
    init(connectedDescriptor fd: Int32) {
        self.fileDescriptor = fd
        self.queue = DispatchQueue(label: "org.librescrs.libremac.agentclient.socketconnection")
        let (stream, continuation) = AsyncThrowingStream<Frame, Error>.makeStream()
        self.frames = stream
        self.continuation = continuation

        Self.configureNonBlockingCloexec(fd)
        Self.setNoSigPipe(fd)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        source.resume()
        self.readSource = source
    }

    deinit {
        // Safety net only — the documented teardown path is close(), which
        // runs on `queue` and waits for both sources to finish cancelling
        // before closing the fd (see performClose). A dispatch source must
        // be cancelled before its last reference is released, or libdispatch
        // traps; calling cancel() here (even without waiting for the
        // cancellation to complete) keeps that contract if a caller drops
        // the last reference without calling close() first.
        guard !isClosed else { return }
        readSource?.cancel()
        writeSource?.cancel()
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
        }
    }

    // MARK: - Sending

    /// Encodes and queues one frame for delivery, taking ownership of
    /// `fds` (see the type doc comment's "fd ownership" section). Validates
    /// `body`/`fds` against the frame caps synchronously — mirroring
    /// `Frame.encodeHeader` — before ever touching `queue`, so a
    /// caller-side size bug is reported immediately rather than silently
    /// dropped. On a throw, NOTHING was enqueued and ownership of `fds`
    /// stays with the caller (none closed here) — the caller must close
    /// them itself, as `AgentClient.call` does. The actual write is
    /// asynchronous; IO-level failures surface through `frames` throwing
    /// `.io`, not through this call.
    public func send(body: Data, fds: [Int32] = []) throws(FrameError) {
        let header = try Frame.encodeHeader(bodyLength: body.count, fdCount: fds.count)
        let framed = [UInt8](header) + [UInt8](body)
        queue.async { [weak self] in
            self?.enqueue(bytes: framed, fds: fds)
        }
    }

    private func enqueue(bytes: [UInt8], fds: [Int32]) {
        guard !isClosed else {
            for fd in fds {
                Darwin.close(fd)
            }
            return
        }
        outbox.append(PendingFrame(bytes: bytes, fds: fds))
        flushOutbox()
    }

    private func flushOutbox() {
        guard !isClosed else { return }
        while !outbox.isEmpty {
            switch trySend(frame: &outbox[0]) {
            case .sent:
                for fd in outbox[0].fds {
                    Darwin.close(fd)
                }
                outbox.removeFirst()
            case .wouldBlock:
                installWriteSourceIfNeeded()
                return
            case .ioError:
                terminate(with: .io)
                return
            }
        }
        // Outbox drained: tear down the (backpressure-only) write source.
        if let writeSource {
            writeSource.cancel()
            self.writeSource = nil
        }
    }

    /// Drives one `PendingFrame` as far as it will go without blocking.
    /// fds ride ONLY the very first `sendmsg` attempted for this frame
    /// (success or partial write) — every retry after that, whether for
    /// the rest of this frame or a later one, is a plain `write()`. This is
    /// the mandatory correctness point: a partial first `sendmsg` must not
    /// cause the fds to be re-attached on the retry.
    private func trySend(frame: inout PendingFrame) -> SendOutcome {
        while frame.offset < frame.bytes.count {
            let attachFds = !frame.fdsAttached && !frame.fds.isEmpty
            let (written, sendErrno) = attachFds
                ? sendWithFds(bytes: frame.bytes, offset: frame.offset, fds: frame.fds)
                : plainWrite(bytes: frame.bytes, offset: frame.offset)

            if written < 0 {
                if sendErrno == EINTR {
                    continue
                }
                if sendErrno == EAGAIN || sendErrno == EWOULDBLOCK {
                    return .wouldBlock
                }
                return .ioError(sendErrno)
            }
            if attachFds {
                frame.fdsAttached = true
            }
            frame.offset += written
        }
        return .sent
    }

    private func sendWithFds(bytes: [UInt8], offset: Int, fds: [Int32]) -> (Int, Int32) {
        var outcome: (Int, Int32) = (-1, EINVAL)
        bytes.withUnsafeBytes { rawBytes in
            var iov = iovec(
                iov_base: UnsafeMutableRawPointer(mutating: rawBytes.baseAddress!.advanced(by: offset)),
                iov_len: rawBytes.count - offset
            )
            let payloadBytes = fds.count * MemoryLayout<Int32>.size
            var control = [UInt8](repeating: 0, count: Self.cmsgSpace(payloadBytes))
            control.withUnsafeMutableBytes { controlRaw in
                let header = controlRaw.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                header.pointee.cmsg_len = socklen_t(Self.cmsgLen(payloadBytes))
                header.pointee.cmsg_level = SOL_SOCKET
                header.pointee.cmsg_type = SCM_RIGHTS
                let dataPtr = (controlRaw.baseAddress! + Self.cmsgHeaderSize).assumingMemoryBound(to: Int32.self)
                for (index, fd) in fds.enumerated() {
                    dataPtr[index] = fd
                }

                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    var msg = msghdr()
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = controlRaw.baseAddress
                    msg.msg_controllen = socklen_t(controlRaw.count)
                    let sent = Darwin.sendmsg(fileDescriptor, &msg, 0)
                    outcome = sent < 0 ? (-1, errno) : (sent, 0)
                }
            }
        }
        return outcome
    }

    private func plainWrite(bytes: [UInt8], offset: Int) -> (Int, Int32) {
        var outcome: (Int, Int32) = (-1, EINVAL)
        bytes.withUnsafeBytes { rawBytes in
            let base = rawBytes.baseAddress!.advanced(by: offset)
            let written = Darwin.write(fileDescriptor, base, rawBytes.count - offset)
            outcome = written < 0 ? (-1, errno) : (written, 0)
        }
        return outcome
    }

    private func installWriteSourceIfNeeded() {
        guard writeSource == nil, fileDescriptor >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.flushOutbox()
        }
        source.resume()
        writeSource = source
    }

    // MARK: - Receiving

    private func handleReadable() {
        guard !isClosed else { return }
        readLoop: while true {
            switch recvOnce() {
            case .data(let bytes, let fds):
                do {
                    let completed = try reassembler.pump(bytes: Data(bytes), fds: fds)
                    for frame in completed {
                        continuation.yield(frame)
                    }
                } catch {
                    // `FrameReassembler.pump` is `throws(FrameError)`, so
                    // `error` is already typed as `FrameError` here.
                    terminate(with: error)
                    return
                }
            case .wouldBlock:
                break readLoop
            case .interrupted:
                continue // signal-interrupted recvmsg: retry, never tear down
            case .eof:
                terminate(with: .peerClosed)
                return
            case .ioError:
                terminate(with: .io)
                return
            }
        }
    }

    /// One `recvmsg` call. The data buffer is sized generously above the
    /// frame header so small frames complete in one call; large bodies
    /// simply span multiple calls (streamed through `FrameReassembler`).
    /// The control buffer is ALWAYS sized for `kMaxFrameFds` regardless of
    /// how many fds this particular call actually carries — the received
    /// fd count is not known until the kernel fills it in.
    private func recvOnce() -> ReadOutcome {
        var bodyBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        var controlBuffer = [UInt8](repeating: 0, count: Self.controlBufferSize)
        var iov = iovec()
        var outcome: ReadOutcome = .wouldBlock

        bodyBuffer.withUnsafeMutableBytes { bodyRaw in
            controlBuffer.withUnsafeMutableBytes { controlRaw in
                iov.iov_base = bodyRaw.baseAddress
                iov.iov_len = bodyRaw.count
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    var msg = msghdr()
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = controlRaw.baseAddress
                    msg.msg_controllen = socklen_t(controlRaw.count)

                    let received = Darwin.recvmsg(fileDescriptor, &msg, 0)
                    if received < 0 {
                        let failure = errno
                        if failure == EAGAIN || failure == EWOULDBLOCK {
                            outcome = .wouldBlock
                        } else if failure == EINTR {
                            outcome = .interrupted // retry; symmetric with trySend
                        } else {
                            outcome = .ioError(failure)
                        }
                        return
                    }
                    if received == 0 {
                        outcome = .eof
                        return
                    }
                    // The control buffer is sized for kMaxFrameFds; a
                    // well-behaved peer (including every other
                    // SocketConnection) never exceeds that. MSG_CTRUNC means
                    // the ancillary data was truncated — some received fds
                    // were silently dropped by the kernel — so this read
                    // cannot be trusted; fail closed rather than risk
                    // misattributing fds to the wrong frame. Mirrors the
                    // peer agent's `recvExact` MSG_CTRUNC handling.
                    if msg.msg_flags & MSG_CTRUNC != 0 {
                        outcome = .ioError(EMSGSIZE)
                        return
                    }
                    let fds = Self.extractFds(msg: msg, controlBase: controlRaw.baseAddress)
                    outcome = .data(bytes: Array(bodyRaw[0..<received]), fds: fds)
                }
            }
        }
        return outcome
    }

    /// Walks the ancillary-data chain looking for SCM_RIGHTS entries,
    /// setting `FD_CLOEXEC` on every fd found — Darwin has no
    /// `MSG_CMSG_CLOEXEC`, so this is the only place
    /// that happens. Reimplements `CMSG_FIRSTHDR`/`CMSG_NXTHDR` by hand:
    /// those are C macros (pointer arithmetic over `msghdr`/`cmsghdr`), not
    /// functions, so the Darwin module does not import them for Swift.
    private static func extractFds(msg: msghdr, controlBase: UnsafeRawPointer?) -> [Int32] {
        guard let controlBase else { return [] }
        let total = Int(msg.msg_controllen)
        var fds: [Int32] = []
        var offset = 0
        while offset + cmsgHeaderSize <= total {
            let header = (controlBase + offset).assumingMemoryBound(to: cmsghdr.self).pointee
            let length = Int(header.cmsg_len)
            guard length >= cmsgHeaderSize, offset + length <= total else { break }
            if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
                let payloadStart = offset + cmsgHeaderSize
                let payloadBytes = length - cmsgHeaderSize
                let count = payloadBytes / MemoryLayout<Int32>.size
                let data = (controlBase + payloadStart).assumingMemoryBound(to: Int32.self)
                for index in 0..<count {
                    let fd = data[index]
                    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                    fds.append(fd)
                }
            }
            offset += cmsgAlign(length)
        }
        return fds
    }

    // MARK: - Closing

    /// Closes the connection. Idempotent — a second call no-ops. Cancels
    /// both dispatch sources, closes the fd only once both cancellations
    /// have completed (the GCD contract for a dispatch source over an fd:
    /// the fd must outlive every source monitoring it), closes any fds
    /// still owned by queued outbound frames and any fds
    /// `FrameReassembler` received but never attributed to a frame, and
    /// finishes `frames` cleanly (no error — this is a local, intentional
    /// close, not a protocol/IO failure).
    public func close() {
        queue.async { [weak self] in
            self?.performClose(throwing: nil)
        }
    }

    private func terminate(with error: FrameError) {
        performClose(throwing: error)
    }

    private func performClose(throwing error: FrameError?) {
        guard !isClosed else { return }
        isClosed = true

        for frame in outbox {
            for fd in frame.fds {
                Darwin.close(fd)
            }
        }
        outbox.removeAll()
        for fd in reassembler.drainUnattributedFds() {
            Darwin.close(fd)
        }

        let fdToClose = fileDescriptor
        fileDescriptor = -1

        let cancelGroup = DispatchGroup()
        if let readSource {
            cancelGroup.enter()
            readSource.setCancelHandler { cancelGroup.leave() }
            readSource.cancel()
        }
        if let writeSource {
            cancelGroup.enter()
            writeSource.setCancelHandler { cancelGroup.leave() }
            writeSource.cancel()
        }
        readSource = nil
        writeSource = nil
        cancelGroup.notify(queue: queue) {
            if fdToClose >= 0 {
                Darwin.close(fdToClose)
            }
        }

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    // MARK: - Ancillary-data (cmsg) layout helpers
    //
    // CMSG_SPACE/CMSG_LEN/CMSG_FIRSTHDR/CMSG_NXTHDR are C macros in
    // <sys/socket.h>, not functions, so Swift cannot call them directly.
    // Darwin's definitions (confirmed against the SDK header) align every
    // cmsghdr and its payload up to 4 bytes (`__DARWIN_ALIGN32`); since
    // `sizeof(cmsghdr) == 12` is already 4-byte aligned, and the payloads
    // used here (arrays of Int32 fds) are always multiples of 4, alignment
    // is a no-op in practice — reimplemented in full below regardless, so
    // this stays correct if that ever stops being true.

    private static let cmsgHeaderSize = cmsgAlign(MemoryLayout<cmsghdr>.size)
    private static let controlBufferSize = cmsgSpace(MemoryLayout<Int32>.size * kMaxFrameFds)

    private static func cmsgAlign(_ length: Int) -> Int {
        (length + 3) & ~3
    }

    private static func cmsgSpace(_ payloadBytes: Int) -> Int {
        cmsgHeaderSize + cmsgAlign(payloadBytes)
    }

    private static func cmsgLen(_ payloadBytes: Int) -> Int {
        cmsgHeaderSize + payloadBytes
    }

    // MARK: - fd configuration

    private static func configureNonBlockingCloexec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Writing to a peer-closed socket must return `EPIPE`, not raise
    /// `SIGPIPE` (whose default action would terminate the process). Darwin
    /// has no `MSG_NOSIGNAL` send flag for this; `SO_NOSIGPIPE` is the
    /// per-fd equivalent, and it is NOT inherited across `connect()`/
    /// `socketpair()`, so every fd this type owns sets it individually.
    private static func setNoSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Streaming frame reassembler for the dispatch_source client transport
/// (`SocketConnection`). One instance per connection, owned by that
/// connection alone — it is intentionally NOT `Sendable`.
///
/// Mirrors `LibreSCRS::Darwin::wire::FrameReassembler` (`FrameReassembler.h`):
/// fails closed on oversize, fd-count violations, or a body that completes
/// with fewer fds than declared. The sender contract puts a frame's fds on
/// the FIRST sendmsg of that frame, so by the time a frame's body is
/// byte-complete its declared fds must already be in the FIFO — a shortfall
/// is a protocol violation (`FrameError.fdMismatch`), never something to
/// wait out.
///
/// fd attribution follows the same in-order FIFO ("D-Bus UNIX_FDS") model
/// as the C++ side: each completed frame consumes exactly its
/// header-declared `fdCount` fds off the front of the FIFO, in arrival
/// order.
///
/// Error behavior: `pump` fails closed on a protocol violation (`oversize`
/// / `tooManyFds` / `fdMismatch`) by throwing. Once that happens the
/// reassembler is considered dead — every subsequent call to `pump`
/// rethrows the same error immediately, without looking at its buffered
/// bytes/fds again. This mirrors the C++ contract ("the connection is
/// dead") while giving the Swift caller an unambiguous, sticky signal
/// instead of C++'s single-shot `PumpResult.status`.
public final class FrameReassembler {

    private var buffer: [UInt8] = []
    private var fdFifo: [Int32] = []
    private var poisonedError: FrameError?

    public init() {}

    /// Feeds newly-received bytes and out-of-band fds into the reassembler
    /// and returns every frame that became complete as a result, in wire
    /// order. `fds` are appended to the in-order fd FIFO before extraction
    /// runs, so fds delivered in this call attribute to frames completed by
    /// this call's bytes.
    ///
    /// Throws `FrameError.oversize` / `.tooManyFds` on a declared header
    /// value outside the caps — checked immediately after decoding the
    /// 8-byte header and before any body allocation — and `.fdMismatch`
    /// when a frame's body is complete but the FIFO holds fewer fds than
    /// the header declared. Once thrown, every subsequent call throws the
    /// same error (see the type doc comment).
    public func pump(bytes: Data, fds: [Int32] = []) throws(FrameError) -> [Frame] {
        if let poisonedError {
            throw poisonedError
        }

        buffer.append(contentsOf: bytes)
        fdFifo.append(contentsOf: fds)

        var frames: [Frame] = []
        var consumed = 0

        while buffer.count - consumed >= kFrameHeaderBytes {
            let headerStart = consumed
            let headerEnd = headerStart + kFrameHeaderBytes
            let (bodyLength, fdCount) = Frame.decodeHeader(buffer[headerStart..<headerEnd])

            guard bodyLength <= kMaxFrameBytes else {
                poisonedError = .oversize
                throw .oversize
            }
            guard fdCount <= kMaxFrameFds else {
                poisonedError = .tooManyFds
                throw .tooManyFds
            }

            let frameEnd = headerEnd + bodyLength
            guard buffer.count - consumed >= kFrameHeaderBytes + bodyLength else {
                break // body not fully arrived yet; wait for more bytes
            }
            // The frame's bytes are all here; its fds (sent with the frame's
            // first sendmsg) must therefore already be in the FIFO.
            guard fdFifo.count >= fdCount else {
                poisonedError = .fdMismatch
                throw .fdMismatch
            }

            let body = Data(buffer[headerEnd..<frameEnd])
            let frameFds = Array(fdFifo.prefix(fdCount))
            fdFifo.removeFirst(fdCount)
            frames.append(Frame(body: body, fds: frameFds))
            consumed = frameEnd
        }

        if consumed > 0 {
            buffer.removeFirst(consumed)
        }
        return frames
    }

    /// Removes and returns any fds that arrived but were never attributed
    /// to a completed frame — either their frame's body has not fully
    /// arrived yet, or the reassembler was poisoned (see the type doc
    /// comment) before attribution happened. `SocketConnection` calls this
    /// while tearing down a connection so a partial or poisoned frame never
    /// leaks its fds; ownership of the returned fds passes to the caller,
    /// which must close them.
    public func drainUnattributedFds() -> [Int32] {
        defer { fdFifo.removeAll() }
        return fdFifo
    }
}

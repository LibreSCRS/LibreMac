// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Wire protocol version negotiated with the agent. Mirrors the peer
/// agent's `LibreSCRS::Darwin::wire::kProtocolVersion`.
public let kProtocolVersion: UInt32 = 1

/// Byte size of the fixed frame header: `[UInt32 bodyLen LE][UInt32 fdCount
/// LE]`. Mirrors the peer agent's `kFrameHeaderBytes`.
public let kFrameHeaderBytes: Int = 8

/// Frames with a declared body length above this are rejected before any
/// body allocation happens. Mirrors the peer agent's `kMaxFrameBytes`.
public let kMaxFrameBytes: Int = 1 << 20 // 1 MiB

/// Max ancillary fds accepted on one frame (defence-in-depth). Mirrors the
/// peer agent's `kMaxFrameFds` (16 — the reference dbus-daemon's
/// max_message_unix_fds budget, covering a kMaxBatchDocuments SignBatch leg).
public let kMaxFrameFds: Int = 16

/// Frame-level protocol violations. Mirrors the peer agent's `FrameError`
/// minus `WouldBlock`: `.oversize` / `.tooManyFds` /
/// `.fdMismatch` are raised by the pure (I/O-free) `FrameReassembler`;
/// `.peerClosed` / `.io` are raised by `SocketConnection`, the only type in
/// this package that touches a socket. `WouldBlock` has no Swift
/// counterpart — `SocketConnection`'s non-blocking retry loop absorbs EAGAIN
/// internally and never surfaces it to a `Frame` consumer.
public enum FrameError: Error, Sendable, Equatable {
    /// Declared body length exceeds `kMaxFrameBytes`.
    case oversize
    /// Declared fd count exceeds `kMaxFrameFds`.
    case tooManyFds
    /// A frame's body completed with fewer fds available than the header
    /// declared. The sender contract puts a frame's fds on the FIRST
    /// sendmsg of that frame, so they must be in the FIFO by the time the
    /// body is byte-complete — a shortfall is a protocol violation.
    case fdMismatch
    /// The peer closed its end of the connection (clean EOF), before or
    /// between frames. Mirrors `FrameError::PeerClosed`.
    case peerClosed
    /// A `recvmsg`/`sendmsg`/`write` syscall on the connection failed for a
    /// reason other than EAGAIN/EWOULDBLOCK (retried transparently) or a
    /// clean peer close (`.peerClosed`). Mirrors `FrameError::Io`.
    case io
}

/// A decoded frame: the CBOR body plus the fds delivered out-of-band
/// alongside it (in wire order — the body references them by index).
/// Mirrors `LibreSCRS::Darwin::wire::Frame`, minus fd
/// ownership: this package receives fds as plain `Int32` descriptors —
/// `SocketConnection` (added later) is the fd-lifetime owner, this type is
/// a pure value.
public struct Frame: Equatable, Sendable {
    public let body: Data
    public let fds: [Int32]

    public init(body: Data, fds: [Int32] = []) {
        self.body = body
        self.fds = fds
    }
}

extension Frame {

    /// Encodes the fixed 8-byte frame header — `[UInt32 bodyLen
    /// LE][UInt32 fdCount LE]` — for a body of `bodyLength` bytes carrying
    /// `fdCount` fds. Enforces `kMaxFrameBytes` / `kMaxFrameFds` before
    /// building anything beyond the 8-byte header itself, mirroring the
    /// peer agent's `encodeFrame` cap checks. The send path
    /// (`SocketConnection`, added later) prepends this header to the CBOR
    /// body before writing to the socket.
    public static func encodeHeader(bodyLength: Int, fdCount: Int) throws(FrameError) -> Data {
        guard bodyLength >= 0, bodyLength <= kMaxFrameBytes else {
            throw .oversize
        }
        guard fdCount >= 0, fdCount <= kMaxFrameFds else {
            throw .tooManyFds
        }
        var header = Data(capacity: kFrameHeaderBytes)
        appendUInt32LE(UInt32(bodyLength), to: &header)
        appendUInt32LE(UInt32(fdCount), to: &header)
        return header
    }

    /// Decodes a fixed 8-byte frame header. `header` must contain exactly
    /// `kFrameHeaderBytes` bytes; callers (`FrameReassembler`) only invoke
    /// this once that many bytes have accumulated. Decoding never fails —
    /// the declared `bodyLength` / `fdCount` are validated by the caller
    /// against `kMaxFrameBytes` / `kMaxFrameFds` (the "before allocation"
    /// cap check), not here.
    static func decodeHeader<C: Collection>(_ header: C) -> (bodyLength: Int, fdCount: Int) where C.Element == UInt8 {
        let bytes = Array(header)
        precondition(bytes.count == kFrameHeaderBytes, "frame header must be exactly \(kFrameHeaderBytes) bytes")
        let bodyLength = readUInt32LE(bytes, at: 0)
        let fdCount = readUInt32LE(bytes, at: 4)
        return (Int(bodyLength), Int(fdCount))
    }
}

// MARK: - Little-endian UInt32 helpers

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
}

private func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

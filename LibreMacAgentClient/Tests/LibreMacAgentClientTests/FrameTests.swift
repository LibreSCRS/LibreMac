// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
@testable import LibreMacAgentClient

// Wire-format constants exercised here mirror the peer agent's
// Framing.h / FrameReassembler.h: an 8-byte `[UInt32 bodyLen LE][UInt32
// fdCount LE]` header followed by the CBOR body, with fds attributed to
// frames via an in-order FIFO (the D-Bus UNIX_FDS model). Fail-closed
// semantics match the C++ peer verbatim: oversize, fd-count violations,
// and a body that completes with fewer fds than declared all poison the
// reassembler.

@Suite("Frame header encode/decode")
struct FrameHeaderTests {

    @Test("round-trips bodyLen + fdCount through encode/decode")
    func roundTrip() throws {
        let header = try Frame.encodeHeader(bodyLength: 42, fdCount: 3)
        #expect(header.count == kFrameHeaderBytes)
        let decoded = Frame.decodeHeader(header)
        #expect(decoded.bodyLength == 42)
        #expect(decoded.fdCount == 3)
    }

    @Test("round-trips the zero header")
    func roundTripZero() throws {
        let header = try Frame.encodeHeader(bodyLength: 0, fdCount: 0)
        let decoded = Frame.decodeHeader(header)
        #expect(decoded.bodyLength == 0)
        #expect(decoded.fdCount == 0)
    }

    @Test("encodes bodyLen/fdCount little-endian")
    func littleEndianByteOrder() throws {
        // bodyLength = 0x0201, fdCount = 0x0000_0001
        let header = try Frame.encodeHeader(bodyLength: 0x0201, fdCount: 1)
        #expect(Array(header) == [0x01, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
    }

    @Test("rejects bodyLength above kMaxFrameBytes with .oversize")
    func rejectsOversizeBody() {
        #expect(throws: FrameError.oversize) {
            _ = try Frame.encodeHeader(bodyLength: kMaxFrameBytes + 1, fdCount: 0)
        }
    }

    @Test("accepts bodyLength exactly at kMaxFrameBytes")
    func acceptsBoundaryBody() throws {
        let header = try Frame.encodeHeader(bodyLength: kMaxFrameBytes, fdCount: 0)
        #expect(Frame.decodeHeader(header).bodyLength == kMaxFrameBytes)
    }

    @Test("rejects fdCount above kMaxFrameFds with .tooManyFds")
    func rejectsTooManyFds() {
        #expect(throws: FrameError.tooManyFds) {
            _ = try Frame.encodeHeader(bodyLength: 0, fdCount: kMaxFrameFds + 1)
        }
    }

    @Test("accepts fdCount exactly at kMaxFrameFds")
    func acceptsBoundaryFdCount() throws {
        let header = try Frame.encodeHeader(bodyLength: 0, fdCount: kMaxFrameFds)
        #expect(Frame.decodeHeader(header).fdCount == kMaxFrameFds)
    }
}

@Suite("FrameReassembler")
struct FrameReassemblerTests {

    /// Builds the raw wire bytes for one frame: header + body. Does not go
    /// through `Frame.encodeHeader`'s cap checks — tests that need an
    /// out-of-band header (e.g. a declared bodyLength above the cap) build
    /// the header bytes directly so the reassembler's own check is what is
    /// under test, not the encoder's.
    private func rawFrame(body: [UInt8], fdCount: UInt32 = 0) -> [UInt8] {
        var bytes: [UInt8] = []
        let bodyLength = UInt32(body.count)
        bytes.append(UInt8(bodyLength & 0xFF))
        bytes.append(UInt8((bodyLength >> 8) & 0xFF))
        bytes.append(UInt8((bodyLength >> 16) & 0xFF))
        bytes.append(UInt8((bodyLength >> 24) & 0xFF))
        bytes.append(UInt8(fdCount & 0xFF))
        bytes.append(UInt8((fdCount >> 8) & 0xFF))
        bytes.append(UInt8((fdCount >> 16) & 0xFF))
        bytes.append(UInt8((fdCount >> 24) & 0xFF))
        bytes.append(contentsOf: body)
        return bytes
    }

    @Test("delivers a frame fed one byte at a time")
    func oneByteAtATime() throws {
        let body: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let wire = rawFrame(body: body)
        let reassembler = FrameReassembler()

        var delivered: [Frame] = []
        for byte in wire {
            let frames = try reassembler.pump(bytes: Data([byte]))
            delivered.append(contentsOf: frames)
        }

        #expect(delivered.count == 1)
        #expect(delivered.first?.body == Data(body))
        #expect(delivered.first?.fds.isEmpty == true)
    }

    @Test("retains a partial frame across pump calls until it completes")
    func partialFrameRetained() throws {
        let body: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let wire = rawFrame(body: body)
        let reassembler = FrameReassembler()

        // Feed the header plus part of the body: nothing should be emitted.
        let firstChunk = Data(wire.prefix(kFrameHeaderBytes + 3))
        let firstResult = try reassembler.pump(bytes: firstChunk)
        #expect(firstResult.isEmpty)

        // Feed the rest: exactly one frame should now be emitted.
        let secondChunk = Data(wire.suffix(from: kFrameHeaderBytes + 3))
        let secondResult = try reassembler.pump(bytes: secondChunk)
        #expect(secondResult.count == 1)
        #expect(secondResult.first?.body == Data(body))
    }

    @Test("emits two frames delivered in a single chunk, in order")
    func twoFramesInOneChunk() throws {
        let firstBody: [UInt8] = [0x01, 0x02]
        let secondBody: [UInt8] = [0x03, 0x04, 0x05]
        let wire = rawFrame(body: firstBody) + rawFrame(body: secondBody)
        let reassembler = FrameReassembler()

        let frames = try reassembler.pump(bytes: Data(wire))

        #expect(frames.count == 2)
        #expect(frames[0].body == Data(firstBody))
        #expect(frames[1].body == Data(secondBody))
    }

    @Test("attributes fds to a frame in FIFO order")
    func fdAttributionInOrder() throws {
        let body: [UInt8] = [0xAA, 0xBB]
        let wire = rawFrame(body: body, fdCount: 2)
        let reassembler = FrameReassembler()

        let fdA: Int32 = 11
        let fdB: Int32 = 22
        let frames = try reassembler.pump(bytes: Data(wire), fds: [fdA, fdB])

        #expect(frames.count == 1)
        #expect(frames.first?.fds == [fdA, fdB])
    }

    @Test("rejects a body that completes with fewer fds than declared with .fdMismatch")
    func bodyCompleteWithMissingFdsFailsClosed() throws {
        // The sender contract puts a frame's fds on the FIRST sendmsg of
        // that frame, so a byte-complete body with an fd shortfall is a
        // protocol violation, never something to wait out.
        let wire = rawFrame(body: [0x01], fdCount: 2)
        let reassembler = FrameReassembler()
        #expect(throws: FrameError.fdMismatch) {
            _ = try reassembler.pump(bytes: Data(wire), fds: [100]) // 1 of 2
        }
        // The reassembler is poisoned like any other violation.
        #expect(throws: FrameError.fdMismatch) {
            _ = try reassembler.pump(bytes: Data(rawFrame(body: [0x02])))
        }
    }

    @Test("emits a frame whose fds arrived with the first body bytes, body completing later")
    func fdsArriveWithFirstBodyBytes() throws {
        let body: [UInt8] = [0x10, 0x20, 0x30]
        let wire = rawFrame(body: body, fdCount: 2)
        let reassembler = FrameReassembler()

        let fdA: Int32 = 100
        let fdB: Int32 = 200

        // First pump: header + first body byte, with both fds riding along
        // (the sender-contract shape). The body is incomplete, so nothing
        // is emitted yet — but no error either.
        let firstChunk = Data(wire.prefix(kFrameHeaderBytes + 1))
        let firstResult = try reassembler.pump(bytes: firstChunk, fds: [fdA, fdB])
        #expect(firstResult.isEmpty)

        // Second pump: the rest of the body, no new fds. The frame
        // completes with its fds attributed in order.
        let secondChunk = Data(wire.suffix(from: kFrameHeaderBytes + 1))
        let secondResult = try reassembler.pump(bytes: secondChunk)
        #expect(secondResult.count == 1)
        #expect(secondResult.first?.body == Data(body))
        #expect(secondResult.first?.fds == [fdA, fdB])
    }

    @Test("handles a chunk boundary exactly between frame 1's last body byte and frame 2's header")
    func chunkBoundaryBetweenFrames() throws {
        let firstBody: [UInt8] = [0x01, 0x02]
        let secondBody: [UInt8] = [0x03, 0x04, 0x05]
        let firstWire = rawFrame(body: firstBody)
        let secondWire = rawFrame(body: secondBody)
        let reassembler = FrameReassembler()

        // Chunk 1 ends exactly on frame 1's last body byte.
        let firstResult = try reassembler.pump(bytes: Data(firstWire))
        #expect(firstResult.count == 1)
        #expect(firstResult.first?.body == Data(firstBody))

        // Chunk 2 starts exactly at frame 2's header.
        let secondResult = try reassembler.pump(bytes: Data(secondWire))
        #expect(secondResult.count == 1)
        #expect(secondResult.first?.body == Data(secondBody))
    }

    @Test("rejects a declared bodyLength above kMaxFrameBytes with .oversize")
    func rejectsOversizeFrame() {
        // Build only the header — a real oversize body would be
        // impractical to allocate in a test, and the reassembler must
        // reject based on the header alone, before waiting for (let alone
        // allocating) the body.
        var header: [UInt8] = []
        let bodyLength = UInt32(kMaxFrameBytes + 1)
        header.append(UInt8(bodyLength & 0xFF))
        header.append(UInt8((bodyLength >> 8) & 0xFF))
        header.append(UInt8((bodyLength >> 16) & 0xFF))
        header.append(UInt8((bodyLength >> 24) & 0xFF))
        header.append(contentsOf: [0, 0, 0, 0]) // fdCount = 0

        let reassembler = FrameReassembler()
        #expect(throws: FrameError.oversize) {
            _ = try reassembler.pump(bytes: Data(header))
        }
    }

    @Test("rejects a declared fdCount above kMaxFrameFds with .tooManyFds")
    func rejectsTooManyFdsFrame() {
        let wire = rawFrame(body: [0x01], fdCount: UInt32(kMaxFrameFds) + 1)
        let reassembler = FrameReassembler()
        #expect(throws: FrameError.tooManyFds) {
            _ = try reassembler.pump(bytes: Data(wire))
        }
    }

    @Test("keeps throwing the same error on every pump after a violation")
    func staysPoisonedAfterViolation() throws {
        let wire = rawFrame(body: [0x01], fdCount: UInt32(kMaxFrameFds) + 1)
        let reassembler = FrameReassembler()
        #expect(throws: FrameError.tooManyFds) {
            _ = try reassembler.pump(bytes: Data(wire))
        }
        // A second call, even with unrelated valid-looking bytes, still
        // rethrows the original error — the reassembler is dead.
        #expect(throws: FrameError.tooManyFds) {
            _ = try reassembler.pump(bytes: Data(rawFrame(body: [0x02])))
        }
    }
}

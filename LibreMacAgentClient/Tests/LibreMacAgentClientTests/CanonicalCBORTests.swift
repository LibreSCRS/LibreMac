// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
@testable import LibreMacAgentClient

// Golden vectors are hand-computed from RFC 8949 §4.2 (CORE DETERMINISTIC /
// "canonical" CBOR): shortest-form integers and floats, definite lengths
// only, and map keys ordered by (length ascending, then bytewise content) —
// see CanonicalCBOR.swift's doc comment for the map-key
// rule this mirrors. Every vector below round-trips: decode(bytes) must
// equal the constructed CBORValue, and re-encoding that value must
// reproduce the exact same bytes.

@Suite("CanonicalCBOR golden vectors")
struct CanonicalCBORGoldenVectorTests {

    private func roundTrip(_ value: CBORValue, _ expected: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let expectedData = Data(expected)
        #expect(value.encode() == expectedData, sourceLocation: sourceLocation)
        let decoded = try CBORValue.decode(expectedData)
        #expect(decoded == value, sourceLocation: sourceLocation)
        #expect(decoded.encode() == expectedData, sourceLocation: sourceLocation)
    }

    // MARK: - Unsigned integers (RFC 8949 §3.1 major type 0, §4.2.1 shortest form)

    @Test("uint 0 — immediate value, major 0 additional-info 0")
    func uint0() throws {
        try roundTrip(.int(0), [0x00])
    }

    @Test("uint 23 — largest value encodable as an immediate additional-info byte")
    func uint23() throws {
        try roundTrip(.int(23), [0x17])
    }

    @Test("uint 24 — smallest value requiring the 1-byte extended form (ai=24)")
    func uint24() throws {
        try roundTrip(.int(24), [0x18, 0x18])
    }

    @Test("uint 255 — largest value fitting the 1-byte extended form")
    func uint255() throws {
        try roundTrip(.int(255), [0x18, 0xFF])
    }

    @Test("uint 256 — smallest value requiring the 2-byte extended form (ai=25)")
    func uint256() throws {
        try roundTrip(.int(256), [0x19, 0x01, 0x00])
    }

    @Test("uint 65535 — largest value fitting the 2-byte extended form")
    func uint65535() throws {
        try roundTrip(.int(65535), [0x19, 0xFF, 0xFF])
    }

    @Test("uint 65536 — smallest value requiring the 4-byte extended form (ai=26)")
    func uint65536() throws {
        try roundTrip(.int(65536), [0x1A, 0x00, 0x01, 0x00, 0x00])
    }

    @Test("Int64.max normalizes through .uint and .int identically")
    func int64MaxNormalization() throws {
        let bytes: [UInt8] = [0x1B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] // major0, ai=27, 8-byte arg = Int64.max
        #expect(CBORValue.int(Int64.max).encode() == Data(bytes))
        #expect(CBORValue.uint(UInt64(Int64.max)).encode() == Data(bytes))
        let decoded = try CBORValue.decode(Data(bytes))
        #expect(decoded == .int(Int64.max)) // decode normalizes to .int, never .uint, for values <= Int64.max
    }

    @Test("Int64.max + 1 decodes as .uint (first value NOT representable as .int)")
    func int64MaxPlusOneStaysUInt() throws {
        let value = UInt64(Int64.max) + 1 // 9223372036854775808
        let bytes: [UInt8] = [0x1B, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        try roundTrip(.uint(value), bytes)
    }

    // MARK: - Negative integers (RFC 8949 §3.1 major type 1; value = -1 - argument)

    @Test("negative int -1 — immediate argument 0")
    func negativeOne() throws {
        try roundTrip(.int(-1), [0x20])
    }

    @Test("negative int -500 — argument 499 requires the 2-byte extended form")
    func negativeFiveHundred() throws {
        // -500 = -1 - 499; 499 = 0x01F3 > 255, so the 2-byte form (ai=25) is the shortest.
        try roundTrip(.int(-500), [0x39, 0x01, 0xF3])
    }

    // MARK: - Byte strings / text strings (RFC 8949 §3.1 major types 2 and 3)

    @Test("bstr h'01020304' — major 2, length 4")
    func byteString() throws {
        try roundTrip(.bytes(Data([0x01, 0x02, 0x03, 0x04])), [0x44, 0x01, 0x02, 0x03, 0x04])
    }

    @Test("tstr \"IETF\" — major 3, length 4 (RFC 8949 Appendix A example)")
    func textString() throws {
        try roundTrip(.text("IETF"), [0x64, 0x49, 0x45, 0x54, 0x46])
    }

    // MARK: - Containers (RFC 8949 §3.1 major types 4 and 5)

    @Test("array [1, 2, 3] — major 4, count 3 (RFC 8949 Appendix A example)")
    func array123() throws {
        try roundTrip(.array([.int(1), .int(2), .int(3)]), [0x83, 0x01, 0x02, 0x03])
    }

    @Test("empty array — major 4, count 0")
    func emptyArray() throws {
        try roundTrip(.array([]), [0x80])
    }

    @Test("empty map — major 5, count 0")
    func emptyMap() throws {
        try roundTrip(.map([]), [0xA0])
    }

    @Test("map {\"b\":1,\"aa\":2} — canonical key order is length-first, NOT alphabetical")
    func mapCanonicalKeyOrder() throws {
        // "b" (length 1) sorts before "aa" (length 2) even though 'a' < 'b'
        // alphabetically — RFC 8949 §4.2.1's length-first rule, mirroring
        // CanonicalKeyLess. Constructed with keys in
        // insertion order "aa" then "b" to prove encode() sorts them.
        let value = CBORValue.map([(Data("aa".utf8), .int(2)), (Data("b".utf8), .int(1))])
        let expected: [UInt8] = [
            0xA2,                   // map, 2 pairs
            0x61, 0x62, 0x01,       // "b": 1
            0x62, 0x61, 0x61, 0x02, // "aa": 2
        ]
        #expect(value.encode() == Data(expected))
        let decoded = try CBORValue.decode(Data(expected))
        #expect(decoded.encode() == Data(expected))
    }

    // MARK: - Simple values (RFC 8949 §3.3 major type 7)

    @Test("bool true / false")
    func bools() throws {
        try roundTrip(.bool(true), [0xF5])
        try roundTrip(.bool(false), [0xF4])
    }

    @Test("null")
    func null() throws {
        try roundTrip(.null, [0xF6])
    }

    // MARK: - Floats: shortest value-preserving width (QCBOR preferred serialization)

    @Test("0.5 — exactly representable in f16, so f16 is the shortest form")
    func float0_5() throws {
        try roundTrip(.double(0.5), [0xF9, 0x38, 0x00])
    }

    @Test("1.5 — exactly representable in f16")
    func float1_5() throws {
        try roundTrip(.double(1.5), [0xF9, 0x3E, 0x00])
    }

    @Test("100000.0 — out of f16 range (max ~65504), exact in f32")
    func float100000() throws {
        try roundTrip(.double(100000.0), [0xFA, 0x47, 0xC3, 0x50, 0x00])
    }

    @Test("1.1 — not exactly representable in f16 or f32, needs f64")
    func float1_1() throws {
        try roundTrip(.double(1.1), [0xFB, 0x3F, 0xF1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A])
    }

    @Test("+Infinity — exactly representable in f16")
    func floatPositiveInfinity() throws {
        try roundTrip(.double(.infinity), [0xF9, 0x7C, 0x00])
    }

    @Test("NaN always canonicalizes to f9 7e00 regardless of input width")
    func floatNaNCanonicalForm() throws {
        #expect(CBORValue.double(.nan).encode() == Data([0xF9, 0x7E, 0x00]))
        let decoded = try CBORValue.decode(Data([0xF9, 0x7E, 0x00]))
        if case .double(let d) = decoded {
            #expect(d.isNaN)
        } else {
            Issue.record("expected .double(NaN)")
        }
        #expect(decoded.encode() == Data([0xF9, 0x7E, 0x00]))
    }
}

@Suite("CanonicalCBOR strictness rejections")
struct CanonicalCBORStrictnessTests {

    @Test("unsorted map keys are rejected")
    func unsortedMapKeys() {
        // {"aa":1,"b":2} in THIS byte order is wrong: "aa" (length 2) must
        // sort after "b" (length 1).
        let bytes = Data([0xA2, 0x62, 0x61, 0x61, 0x01, 0x61, 0x62, 0x02])
        #expect(throws: CBORError.notCanonical) {
            try CBORValue.decode(bytes)
        }
    }

    @Test("duplicate map key is rejected even when adjacent in sorted position")
    func duplicateMapKey() {
        let bytes = Data([0xA2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02]) // {"a":1,"a":2}
        #expect(throws: CBORError.notCanonical) {
            try CBORValue.decode(bytes)
        }
    }

    @Test("non-shortest-form integer is rejected")
    func nonShortestInt() {
        let bytes = Data([0x18, 0x00]) // 0, encoded via the 1-byte extended form instead of immediate 0x00
        #expect(throws: CBORError.notCanonical) {
            try CBORValue.decode(bytes)
        }
    }

    @Test("float encoded wider than its shortest value-preserving width is rejected")
    func nonShortestFloat() {
        let bytes = Data([0xFA, 0x3F, 0x00, 0x00, 0x00]) // 0.5 as f32; canonical form is f16
        #expect(throws: CBORError.notCanonical) {
            try CBORValue.decode(bytes)
        }
    }

    @Test("indefinite-length array is rejected as unsupported")
    func indefiniteLengthArray() {
        let bytes = Data([0x9F, 0xFF]) // indefinite-length array, immediately closed by "break"
        #expect(throws: CBORError.unsupportedType) {
            try CBORValue.decode(bytes)
        }
    }

    @Test("trailing byte after a complete top-level item is rejected")
    func trailingByte() {
        let bytes = Data([0xF6, 0x00]) // null, then one stray extra byte
        #expect(throws: CBORError.trailingBytes) {
            try CBORValue.decode(bytes)
        }
    }

    @Test("truncated input is rejected")
    func truncatedInput() {
        let bytes = Data([0x44, 0x01, 0x02]) // bstr header claims length 4, only 2 bytes follow
        #expect(throws: CBORError.truncated) {
            try CBORValue.decode(bytes)
        }
    }

    @Test("byte string declaring an Int.max length fails closed instead of trapping")
    func byteStringIntMaxLength() {
        // bstr, ai=27, 8-byte argument 0x7FFF_FFFF_FFFF_FFFF (Int64.max):
        // `index + n` would overflow Int if computed naively.
        let bytes = Data([0x5B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: CBORError.truncated) {
            try CBORValue.decode(bytes)
        }
    }

    @Test("text string declaring an Int.max length fails closed instead of trapping")
    func textStringIntMaxLength() {
        // tstr, ai=27, 8-byte argument Int64.max.
        let bytes = Data([0x7B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: CBORError.truncated) {
            try CBORValue.decode(bytes)
        }
    }

    @Test("nested byte string declaring an Int.max length fails closed instead of trapping")
    func nestedByteStringIntMaxLength() {
        // Array of one element wrapping the hostile bstr, so the overflow
        // candidate `index` is deeper into the buffer than the top-level case.
        let bytes = Data([0x81, 0x5B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: CBORError.truncated) {
            try CBORValue.decode(bytes)
        }
    }

    @Test("invalid UTF-8 text string is rejected")
    func invalidUTF8() {
        let bytes = Data([0x61, 0xFF]) // tstr, length 1, byte 0xFF is not valid UTF-8
        #expect(throws: CBORError.invalidUTF8) {
            try CBORValue.decode(bytes)
        }
    }

    // MARK: - Depth cap (16): raw bytes built by hand-wrapping "array of one
    // element" (0x81) headers around an innermost uint-0 scalar (0x00), so
    // this exercises the parser without going through CBORValue.encode().

    private func nestedArrayBytes(depth: Int) -> Data {
        var bytes = Data([0x00])
        for _ in 0..<depth {
            bytes = Data([0x81]) + bytes
        }
        return bytes
    }

    @Test("exactly 16 levels of array nesting is accepted")
    func depth16Accepted() throws {
        let bytes = nestedArrayBytes(depth: 16)
        let decoded = try CBORValue.decode(bytes)
        #expect(decoded.encode() == bytes)
    }

    @Test("17 levels of array nesting is rejected")
    func depth17Rejected() {
        let bytes = nestedArrayBytes(depth: 17)
        #expect(throws: CBORError.tooDeep) {
            try CBORValue.decode(bytes)
        }
    }

    // MARK: - Item cap (4096): raw bytes for an array of N uint-0 elements,
    // built by hand (2-byte length header, ai=25, since N > 255 here).

    private func arrayOfZerosBytes(count: Int) -> Data {
        precondition(count > 255 && count <= 0xFFFF)
        var bytes = Data([0x99, UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)])
        bytes.append(Data(repeating: 0x00, count: count))
        return bytes
    }

    @Test("array with 4095 elements (4096 items incl. the array itself) is accepted")
    func itemCapBoundaryAccepted() throws {
        let bytes = arrayOfZerosBytes(count: 4095)
        let decoded = try CBORValue.decode(bytes)
        #expect(decoded.encode() == bytes)
    }

    @Test("array with 4096 elements (4097 items incl. the array itself) is rejected")
    func itemCapBoundaryRejected() {
        let bytes = arrayOfZerosBytes(count: 4096)
        #expect(throws: CBORError.tooManyItems) {
            try CBORValue.decode(bytes)
        }
    }
}

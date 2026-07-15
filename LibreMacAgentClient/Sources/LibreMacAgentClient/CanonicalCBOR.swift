// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// One complete CBOR (RFC 8949) value in the closed subset used by the
/// LibreMac agent wire protocol: unsigned/negative integers, byte strings,
/// UTF-8 text strings, arrays, maps, booleans, null, and IEEE 754 floating
/// point.
///
/// `encode()` always produces the RFC 8949 §4.2 CORE DETERMINISTIC
/// ("canonical") byte sequence: shortest-form integers, definite lengths,
/// floats at the shortest value-preserving width, and map keys ordered by
/// (length ascending, then bytewise content) — the same rule as the peer
/// agent's `CanonicalKeyLess`. For text-string keys this
/// length-first order is identical to the full §4.2 bytewise order of the
/// encoded keys, because the CBOR text-string length header is strictly
/// monotonic in length.
///
/// `decode(_:)` is strict and bounded (untrusted-input posture even though
/// the peer is a trusted same-uid agent): it accepts ONLY canonical input —
/// shortest-form integers and floats, definite lengths, sorted unique map
/// keys, no trailing bytes, nesting depth <= `maxDepth`, and item count
/// <= `maxItems` — and rejects everything else fail-closed via `CBORError`.
public enum CBORValue: Equatable, Sendable {
    case int(Int64)
    case uint(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBORValue])
    case map([(Data, CBORValue)])
    case bool(Bool)
    case null
    case double(Double)

    public static func == (lhs: CBORValue, rhs: CBORValue) -> Bool {
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)):
            return a == b
        case (.uint(let a), .uint(let b)):
            return a == b
        case (.bytes(let a), .bytes(let b)):
            return a == b
        case (.text(let a), .text(let b)):
            return a == b
        case (.array(let a), .array(let b)):
            return a == b
        case (.map(let a), .map(let b)):
            guard a.count == b.count else { return false }
            for (l, r) in zip(a, b) where l.0 != r.0 || l.1 != r.1 {
                return false
            }
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.null, .null):
            return true
        case (.double(let a), .double(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Decode failure modes. Mirrors the peer agent's `CborError`,
/// split further where Swift's typed-throws surface
/// benefits from a more specific case (`.truncated`, `.invalidUTF8`).
public enum CBORError: Error, Sendable, Equatable {
    /// Fewer bytes were available than a header claimed.
    case truncated
    /// Bytes could not be parsed as CBOR at all (reserved additional-info
    /// values, or other structurally invalid encodings).
    case malformed
    /// The bytes decoded but were not RFC 8949 §4.2 canonical (non-shortest
    /// integer or float, unsorted or duplicate map keys).
    case notCanonical
    /// A CBOR major type or simple value outside our closed subset (tags,
    /// indefinite-length items, simple values other than false/true/null).
    case unsupportedType
    /// Nesting exceeded `CBORValue.maxDepth`.
    case tooDeep
    /// Decoded item count exceeded `CBORValue.maxItems`.
    case tooManyItems
    /// Extra bytes followed a complete top-level item.
    case trailingBytes
    /// A text string's bytes were not valid UTF-8.
    case invalidUTF8
}

extension CBORValue {

    /// Maximum container nesting depth accepted by `decode(_:)`. A chain of
    /// exactly `maxDepth` nested arrays/maps is accepted; `maxDepth + 1` is
    /// rejected with `.tooDeep`. Mirrors the peer agent's `kMaxCborDepth`.
    public static let maxDepth = 16

    /// Maximum total decoded item count (every scalar, container, and map
    /// key) accepted by `decode(_:)`. Mirrors the peer agent's
    /// `kMaxCborItems`.
    public static let maxItems = 4096

    /// Canonical (RFC 8949 §4.2) encoding of this value.
    public func encode() -> Data {
        var data = Data()
        writeInto(&data)
        return data
    }

    private func writeInto(_ data: inout Data) {
        switch self {
        case .int(let i):
            if i >= 0 {
                appendHeader(major: 0, argument: UInt64(i), into: &data)
            } else {
                // value = -1 - argument; safe for i == Int64.min since
                // -(i + 1) then fits exactly in Int64.max before the widening cast.
                let argument = UInt64(-(i + 1))
                appendHeader(major: 1, argument: argument, into: &data)
            }
        case .uint(let u):
            appendHeader(major: 0, argument: u, into: &data)
        case .bytes(let b):
            appendHeader(major: 2, argument: UInt64(b.count), into: &data)
            data.append(b)
        case .text(let s):
            let utf8 = Data(s.utf8)
            appendHeader(major: 3, argument: UInt64(utf8.count), into: &data)
            data.append(utf8)
        case .array(let items):
            appendHeader(major: 4, argument: UInt64(items.count), into: &data)
            for item in items {
                item.writeInto(&data)
            }
        case .map(let pairs):
            let sorted = pairs.sorted { canonicalKeyLess($0.0, $1.0) }
            appendHeader(major: 5, argument: UInt64(sorted.count), into: &data)
            for (key, value) in sorted {
                appendHeader(major: 3, argument: UInt64(key.count), into: &data)
                data.append(key)
                value.writeInto(&data)
            }
        case .bool(let b):
            data.append(b ? 0xF5 : 0xF4)
        case .null:
            data.append(0xF6)
        case .double(let d):
            appendDouble(d, into: &data)
        }
    }

    /// Strict, bounded, canonical-checked decode of one complete top-level
    /// item. Rejects trailing bytes, non-canonical encodings, and
    /// over-deep / over-large inputs fail-closed.
    public static func decode(_ data: Data) throws(CBORError) -> CBORValue {
        var parser = CBORParser(bytes: [UInt8](data))
        let value = try parser.parseItem(depth: 1)
        guard parser.index == parser.bytes.count else {
            throw CBORError.trailingBytes
        }
        return value
    }
}

// MARK: - Canonical key order (mirrors the peer agent's CanonicalKeyLess)

/// Length ascending, then bytewise lexicographic content. For text-string
/// keys of any length this is exactly the §4.2 bytewise order of the fully
/// encoded keys, because the text-string length header is strictly
/// monotonic in length.
private func canonicalKeyLess(_ a: Data, _ b: Data) -> Bool {
    if a.count != b.count {
        return a.count < b.count
    }
    return a.lexicographicallyPrecedes(b)
}

// MARK: - Integer header encoding (RFC 8949 §3.1, shortest form)

private func appendHeader(major: UInt8, argument: UInt64, into data: inout Data) {
    let majorBits = major << 5
    switch argument {
    case 0..<24:
        data.append(majorBits | UInt8(argument))
    case 24...0xFF:
        data.append(majorBits | 24)
        data.append(UInt8(argument))
    case 0x100...0xFFFF:
        data.append(majorBits | 25)
        data.append(UInt8((argument >> 8) & 0xFF))
        data.append(UInt8(argument & 0xFF))
    case 0x1_0000...0xFFFF_FFFF:
        data.append(majorBits | 26)
        appendBigEndian(argument, byteCount: 4, into: &data)
    default:
        data.append(majorBits | 27)
        appendBigEndian(argument, byteCount: 8, into: &data)
    }
}

private func appendBigEndian(_ value: UInt64, byteCount: Int, into data: inout Data) {
    var shift = (byteCount - 1) * 8
    while shift >= 0 {
        data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        shift -= 8
    }
}

// MARK: - Float encoding: shortest value-preserving width

/// Encodes `value` as CBOR major type 7, choosing f16/f32/f64 — whichever
/// is the narrowest width that preserves the value exactly (QCBOR
/// "preferred serialization"). NaN always canonicalizes to the single
/// value `f9 7e00`; only that canonical NaN is required to round-trip.
private func appendDouble(_ value: Double, into data: inout Data) {
    if value.isNaN {
        data.append(contentsOf: [0xF9, 0x7E, 0x00])
        return
    }
    if let bits16 = f16BitsIfExact(value) {
        data.append(0xF9)
        data.append(UInt8(bits16 >> 8))
        data.append(UInt8(bits16 & 0xFF))
        return
    }
    let f32 = Float(value)
    if Double(f32) == value {
        data.append(0xFA)
        appendBigEndian(UInt64(f32.bitPattern), byteCount: 4, into: &data)
        return
    }
    data.append(0xFB)
    appendBigEndian(value.bitPattern, byteCount: 8, into: &data)
}

/// Returns the IEEE 754 half-precision bit pattern for `value` iff `value`
/// is exactly representable in f16 (no rounding). `value` must be finite,
/// nonzero, and not NaN when reaching the general path; zero and infinity
/// are handled directly. Bit manipulation only — `Float16` does not exist
/// on x86_64 macOS.
private func f16BitsIfExact(_ value: Double) -> UInt16? {
    if value == 0 {
        return value.sign == .minus ? 0x8000 : 0x0000
    }
    if value.isInfinite {
        return value.sign == .minus ? 0xFC00 : 0x7C00
    }
    let bits = value.bitPattern
    let signBit = UInt16((bits >> 63) & 0x1)
    let biasedExponent = Int((bits >> 52) & 0x7FF)
    let fraction = bits & 0xF_FFFF_FFFF_FFFF // low 52 bits

    // A double subnormal (biasedExponent == 0, fraction != 0) is far
    // smaller than the smallest f16 subnormal and is never exact in f16.
    guard biasedExponent != 0 else { return nil }
    let unbiasedExponent = biasedExponent - 1023

    if unbiasedExponent >= -14 && unbiasedExponent <= 15 {
        // f16 NORMAL range: exact iff the low (52 - 10) = 42 fraction bits are zero.
        guard fraction & 0x3_FFFF_FFFF_FF == 0 else { return nil }
        let f16Fraction = UInt16(fraction >> 42)
        let f16Exponent = UInt16(unbiasedExponent + 15)
        return (signBit << 15) | (f16Exponent << 10) | f16Fraction
    }
    if unbiasedExponent >= -24 && unbiasedExponent < -14 {
        // f16 SUBNORMAL range: value = 0.fraction' * 2^-14. Shift the
        // 53-bit significand (implicit leading 1 + 52-bit fraction) right
        // by (42 + extraShift) to land in the 10-bit subnormal mantissa.
        let extraShift = -14 - unbiasedExponent // 1...10
        let significand = (UInt64(1) << 52) | fraction
        let totalShift = 42 + extraShift // 43...52
        let droppedMask = (UInt64(1) << totalShift) - 1
        guard significand & droppedMask == 0 else { return nil }
        let f16Fraction = UInt16(significand >> totalShift)
        guard f16Fraction >= 1 && f16Fraction <= 0x3FF else { return nil }
        return (signBit << 15) | f16Fraction
    }
    return nil
}

/// Reconstructs the `Double` for an IEEE 754 half-precision bit pattern.
/// Bit manipulation only — see `f16BitsIfExact` above.
private func doubleFromF16Bits(_ bits: UInt16) -> Double {
    let sign = UInt64(bits >> 15) & 0x1
    let exponent = Int((bits >> 10) & 0x1F)
    let fraction = UInt64(bits & 0x3FF)

    var doubleBits: UInt64 = sign << 63
    if exponent == 0 {
        if fraction != 0 {
            // Subnormal f16: normalize by shifting the leading 1 bit out of
            // the 10-bit fraction (loop runs at most 10 times).
            var f = fraction
            var e = -14
            while f & 0x400 == 0 {
                f <<= 1
                e -= 1
            }
            f &= 0x3FF
            doubleBits |= UInt64(e + 1023) << 52
            doubleBits |= f << 42
        }
        // else +/-0.0: sign bit already set, remainder zero.
    } else if exponent == 0x1F {
        doubleBits |= UInt64(0x7FF) << 52
        if fraction != 0 {
            doubleBits |= UInt64(1) << 51 // quiet-NaN payload bit; exact payload is not preserved
        }
    } else {
        doubleBits |= UInt64(exponent - 15 + 1023) << 52
        doubleBits |= fraction << 42
    }
    return Double(bitPattern: doubleBits)
}

/// The minimal width (16/32/64) that preserves `value` exactly. `value`
/// must be finite or infinite, never NaN (NaN canonicalization is handled
/// separately by its callers).
private func shortestFloatWidth(for value: Double) -> Int {
    if f16BitsIfExact(value) != nil {
        return 16
    }
    if Double(Float(value)) == value {
        return 32
    }
    return 64
}

// MARK: - Decoder

private struct CBORParser {
    let bytes: [UInt8]
    var index: Int = 0
    var itemCount: Int = 0

    mutating func requireByte() throws(CBORError) -> UInt8 {
        guard index < bytes.count else { throw .truncated }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func requireBytes(_ n: Int) throws(CBORError) -> ArraySlice<UInt8> {
        guard index + n <= bytes.count else { throw .truncated }
        defer { index += n }
        return bytes[index..<(index + n)]
    }

    mutating func countItem() throws(CBORError) {
        itemCount += 1
        guard itemCount <= CBORValue.maxItems else { throw .tooManyItems }
    }

    /// Reads the shortest-form argument that follows an additional-info
    /// nibble `ai` already read from the item's first byte. Rejects
    /// non-shortest encodings as `.notCanonical` and reserved additional-info
    /// values (28-30) as `.malformed`. `ai == 31` (indefinite length /
    /// break) is the caller's responsibility to reject or handle.
    mutating func readArgument(_ ai: UInt8) throws(CBORError) -> UInt64 {
        switch ai {
        case 0..<24:
            return UInt64(ai)
        case 24:
            let b = try requireByte()
            guard b >= 24 else { throw .notCanonical }
            return UInt64(b)
        case 25:
            let v = try readBigEndian(2)
            guard v > 0xFF else { throw .notCanonical }
            return v
        case 26:
            let v = try readBigEndian(4)
            guard v > 0xFFFF else { throw .notCanonical }
            return v
        case 27:
            let v = try readBigEndian(8)
            guard v > 0xFFFF_FFFF else { throw .notCanonical }
            return v
        case 28, 29, 30:
            throw .malformed
        default: // 31
            throw .malformed
        }
    }

    mutating func readBigEndian(_ byteCount: Int) throws(CBORError) -> UInt64 {
        let slice = try requireBytes(byteCount)
        var v: UInt64 = 0
        for b in slice {
            v = (v << 8) | UInt64(b)
        }
        return v
    }

    mutating func parseItem(depth: Int) throws(CBORError) -> CBORValue {
        try countItem()
        let first = try requireByte()
        let major = first >> 5
        let ai = first & 0x1F

        switch major {
        case 0:
            let argument = try readArgument(ai)
            return normalizedUInt(argument)
        case 1:
            let argument = try readArgument(ai)
            guard argument <= UInt64(Int64.max) else { throw .unsupportedType }
            return .int(-1 - Int64(argument))
        case 2:
            guard ai != 31 else { throw .unsupportedType }
            let length = try lengthArgument(ai)
            let slice = try requireBytes(length)
            return .bytes(Data(slice))
        case 3:
            guard ai != 31 else { throw .unsupportedType }
            let length = try lengthArgument(ai)
            let slice = try requireBytes(length)
            guard let text = String(bytes: slice, encoding: .utf8) else { throw .invalidUTF8 }
            return .text(text)
        case 4:
            guard ai != 31 else { throw .unsupportedType }
            guard depth <= CBORValue.maxDepth else { throw .tooDeep }
            let count = try lengthArgument(ai)
            var items: [CBORValue] = []
            items.reserveCapacity(min(count, 1024))
            for _ in 0..<count {
                items.append(try parseItem(depth: depth + 1))
            }
            return .array(items)
        case 5:
            guard ai != 31 else { throw .unsupportedType }
            guard depth <= CBORValue.maxDepth else { throw .tooDeep }
            let count = try lengthArgument(ai)
            var pairs: [(Data, CBORValue)] = []
            pairs.reserveCapacity(min(count, 1024))
            for _ in 0..<count {
                let key = try parseMapKey()
                let value = try parseItem(depth: depth + 1)
                pairs.append((key, value))
            }
            if pairs.count > 1 {
                for i in 1..<pairs.count {
                    guard canonicalKeyLess(pairs[i - 1].0, pairs[i].0) else {
                        throw .notCanonical // not strictly ascending: unsorted or duplicate key
                    }
                }
            }
            return .map(pairs)
        case 6:
            throw .unsupportedType
        case 7:
            return try parseSimpleOrFloat(ai)
        default:
            throw .malformed
        }
    }

    /// Reads a map key: must be a definite-length text string (major 3).
    /// Counts as a decoded item distinct from its value.
    mutating func parseMapKey() throws(CBORError) -> Data {
        try countItem()
        let first = try requireByte()
        let major = first >> 5
        let ai = first & 0x1F
        guard major == 3, ai != 31 else { throw .unsupportedType }
        let length = try lengthArgument(ai)
        let slice = try requireBytes(length)
        guard String(bytes: slice, encoding: .utf8) != nil else { throw .invalidUTF8 }
        return Data(slice)
    }

    mutating func lengthArgument(_ ai: UInt8) throws(CBORError) -> Int {
        let value = try readArgument(ai)
        guard let n = Int(exactly: value) else { throw .unsupportedType }
        return n
    }

    func normalizedUInt(_ value: UInt64) -> CBORValue {
        if value <= UInt64(Int64.max) {
            return .int(Int64(value))
        }
        return .uint(value)
    }

    mutating func parseSimpleOrFloat(_ ai: UInt8) throws(CBORError) -> CBORValue {
        switch ai {
        case 20:
            return .bool(false)
        case 21:
            return .bool(true)
        case 22:
            return .null
        case 25:
            let raw = try readBigEndian(2)
            let bits16 = UInt16(raw)
            let value = doubleFromF16Bits(bits16)
            try checkCanonicalFloat(value: value, actualWidth: 16, bits16: bits16)
            return .double(value)
        case 26:
            let raw = try readBigEndian(4)
            let value = Double(Float(bitPattern: UInt32(raw)))
            try checkCanonicalFloat(value: value, actualWidth: 32, bits16: nil)
            return .double(value)
        case 27:
            let raw = try readBigEndian(8)
            let value = Double(bitPattern: raw)
            try checkCanonicalFloat(value: value, actualWidth: 64, bits16: nil)
            return .double(value)
        case 28, 29, 30:
            throw .malformed
        case 31: // break, outside an indefinite-length context
            throw .unsupportedType
        default: // 0...19 (unassigned/reserved simple values), 23 (undefined), 24 (1-byte simple value)
            if ai == 24 {
                _ = try requireByte()
            }
            throw .unsupportedType
        }
    }

    func checkCanonicalFloat(value: Double, actualWidth: Int, bits16: UInt16?) throws(CBORError) {
        if value.isNaN {
            guard actualWidth == 16, bits16 == 0x7E00 else { throw .notCanonical }
            return
        }
        guard actualWidth == shortestFloatWidth(for: value) else { throw .notCanonical }
    }
}

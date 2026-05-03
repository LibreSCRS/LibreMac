// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Heap-allocated UTF-8 byte buffer that is overwritten with zeros on
/// deinitialisation. Mirrors `LibreSCRS::Secure::String` semantics on the
/// Swift side: any credential material that crosses the bridge is wrapped
/// in `SecureString` while held by the host app, then handed to the C++
/// side as a transient `(const char*, size_t)` pair.
///
/// Inspired by Stroustrup *The C++ Programming Language* §13.5 (RAII
/// resource ownership) and Meyers *Effective Modern C++* Item 21 (prefer
/// `std::make_*` for ownership clarity); the Swift parallel is "expose
/// the zeroing invariant in the destructor only, never in user code".
public final class SecureString: @unchecked Sendable {
    private var buffer: UnsafeMutableBufferPointer<UInt8>
    private let observerForTests: (([UInt8]) -> Void)?

    /// Construct from a Swift String (UTF-8 on platform).
    public init(plaintext: String,
                observerForTests: (([UInt8]) -> Void)? = nil) {
        let utf8 = Array(plaintext.utf8)
        let raw = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(utf8.count, 1))
        if !utf8.isEmpty {
            _ = raw.initialize(from: utf8)
        }
        // Truncate the buffer view to exact byte count so withCString reports
        // length matching the input.
        self.buffer = UnsafeMutableBufferPointer(start: raw.baseAddress, count: utf8.count)
        self.observerForTests = observerForTests
    }

    /// Construct from raw bytes; returns nil if the bytes are not valid UTF-8.
    public init?(rawUtf8Bytes: Data) {
        guard String(data: rawUtf8Bytes, encoding: .utf8) != nil else { return nil }
        let raw = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(rawUtf8Bytes.count, 1))
        rawUtf8Bytes.withUnsafeBytes { src in
            _ = raw.initialize(from: src.bindMemory(to: UInt8.self))
        }
        self.buffer = UnsafeMutableBufferPointer(start: raw.baseAddress, count: rawUtf8Bytes.count)
        self.observerForTests = nil
    }

    deinit {
        // Explicit zero first. UnsafeMutableBufferPointer.update has an
        // opaque cross-module body so the optimiser cannot elide the write.
        buffer.update(repeating: 0)
        // Hand the post-zero bytes to the test observer so the observer
        // can confirm the zero actually happened, not just that the
        // observer was invoked. A regression that disabled the update
        // call would now fail the SecureString.zeroOnDealloc test.
        if let observerForTests {
            observerForTests(Array(buffer))
        }
        buffer.deallocate()
    }

    /// Hand the underlying bytes to a closure as `(const char*, size_t)`.
    /// The closure MUST NOT copy the pointer past its return.
    public func withCString<R>(_ body: (UnsafePointer<CChar>, Int) -> R) -> R {
        return buffer.withMemoryRebound(to: CChar.self) { rebound in
            body(UnsafePointer(rebound.baseAddress!), rebound.count)
        }
    }

    /// Length in bytes (UTF-8).
    public var byteCount: Int { buffer.count }
}

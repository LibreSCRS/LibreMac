// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
@testable import LibreMacShared

@Suite("SecureString")
struct SecureStringTests {

    @Test("Roundtrip via withCString preserves bytes")
    func roundtrip() {
        let s = SecureString(plaintext: "1234")
        s.withCString { ptr, len in
            #expect(len == 4)
            #expect(ptr[0] == 0x31 && ptr[3] == 0x34)
        }
    }

    @Test("Buffer is zeroed before deallocate")
    func zeroOnDealloc() {
        // The observer fires AFTER the explicit zero, so its parameter
        // shows what the buffer contains post-zero. A regression that
        // removed the buffer.update(repeating: 0) call would surface
        // here as observed != [0,0,0,0]. We cannot directly observe a
        // freshly-deallocated buffer (that would be UB), so this is the
        // closest we can get to verifying the cleansing invariant.
        var observed: [UInt8] = []
        do {
            let s = SecureString(plaintext: "abcd",
                                 observerForTests: { wiped in observed = wiped })
            s.withCString { _, _ in }
        }
        #expect(observed == [0, 0, 0, 0])
    }

    @Test("Raw UTF-8 bytes accepted and roundtrip")
    func rawUtf8Roundtrip() {
        let bytes: [UInt8] = [0x41, 0x42, 0x43]
        let s = SecureString(rawUtf8Bytes: Data(bytes))
        #expect(s != nil)
        s!.withCString { ptr, len in
            #expect(len == 3)
            #expect(ptr[0] == 0x41)
        }
    }

    @Test("Invalid UTF-8 rejected")
    func rejectsInvalidUtf8() {
        let bytes: [UInt8] = [0xFF, 0xFE]
        let s = SecureString(rawUtf8Bytes: Data(bytes))
        #expect(s == nil)
    }
}

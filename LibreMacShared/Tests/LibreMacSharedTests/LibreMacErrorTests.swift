// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
@testable import LibreMacShared

@Suite("LibreMacError")
struct LibreMacErrorTests {
    @Test("PIN-incorrect renders retry count")
    func pinIncorrectFormat() {
        let e = LibreMacError.pinIncorrect(retriesLeft: 2)
        #expect(e.errorDescription == "PIN incorrect (2 tries left)")
    }

    @Test("PIN-incorrect without count")
    func pinIncorrectNoCount() {
        let e = LibreMacError.pinIncorrect(retriesLeft: nil)
        #expect(e.errorDescription == "PIN incorrect")
    }

    @Test("Equatable across same payload")
    func equatable() {
        let a = LibreMacError.userCancelled
        let b = LibreMacError.userCancelled
        #expect(a == b)
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
@testable import LibreMacAgentClient

@Suite("QuiesceSet")
struct QuiesceSetTests {
    @Test("a lock that outlasts a wake keeps the surface quiesced until the unlock")
    func overlappingReasons() {
        var set = QuiesceSet()
        let lockBegan = set.begin(.screenLocked)
        #expect(lockBegan)
        let sleepBegan = set.begin(.systemSleep)
        #expect(sleepBegan)
        let sleepEnded = set.end(.systemSleep)
        #expect(sleepEnded)
        #expect(!set.isEmpty)
        #expect(set.first == .screenLocked)
        let lockEnded = set.end(.screenLocked)
        #expect(lockEnded)
        #expect(set.isEmpty)
    }

    @Test("a repeated quiesce is one entry, and an end without a begin changes nothing")
    func duplicatesAndStrayEnds() {
        var set = QuiesceSet()
        let began = set.begin(.systemSleep)
        #expect(began)
        let beganAgain = set.begin(.systemSleep)
        #expect(!beganAgain)
        let strayEnd = set.end(.sessionInactive)
        #expect(!strayEnd)
        let ended = set.end(.systemSleep)
        #expect(ended)
        let endedAgain = set.end(.systemSleep)
        #expect(!endedAgain)
        #expect(set.isEmpty)
    }

    @Test("clear forgets every reason")
    func clearForgets() {
        var set = QuiesceSet()
        set.begin(.screenLocked)
        set.begin(.unknown(7))
        set.clear()
        #expect(set.isEmpty)
        #expect(set.first == nil)
    }
}

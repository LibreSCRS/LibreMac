// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Compile-time + lightweight behavioural gate for SigningCoordinator. The
// real end-to-end test requires a real rs-eid card in a CCID reader; that
// is the manual smoke step in Plan B T10.2 (skipped under no-hardware
// policy). Here we cover only the stage gating that does not need a
// session — beginPinEntry() must be a no-op when the monitor reports no
// active session.

import Testing
import LibreMacShared
@testable import LibreMac

@Suite("SigningCoordinator")
@MainActor
struct SigningCoordinatorTests {
    /// Without an active session, `beginPinEntry()` must leave `stage`
    /// untouched. The menu-bar UI gates the "Sign demo payload" button on
    /// `monitor.activeSession != nil`, but the coordinator must still
    /// defend its own invariant.
    @Test("beginPinEntry without active session keeps stage idle")
    func beginPinEntryWithoutSessionStaysIdle() {
        let monitor = CardMonitor()  // no real reader; activeSession is nil
        let coord = SigningCoordinator(cardMonitor: monitor)
        coord.beginPinEntry()
        #expect(coord.stage == .idle)
    }
}

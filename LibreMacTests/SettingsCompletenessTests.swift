// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// A sixth settable key must fail here, by name, rather than the window
// quietly not having it.

import LibreMacAgentClient
import Testing

@testable import LibreMac

@Suite("Settings completeness")
@MainActor
struct SettingsCompletenessTests {

    @Test("every key the agent accepts has a control, or is named as deferred")
    func everySettableKeyIsAccountedFor() {
        let drawn = PreferencesView.settableKeysWithControls
        let deferred = PreferencesView.deferredSettableKeys

        #expect(
            drawn.union(deferred) == Set(SettableConfigKey.allCases),
            "a key was added to the wire and nothing here noticed")
        // Without this second half the guard rots: the deferred list would
        // keep it green forever, including on the day the trust pane draws
        // those very keys.
        #expect(
            drawn.isDisjoint(with: deferred),
            "a key is drawn and still listed as deferred — update the deferred list")
    }
}

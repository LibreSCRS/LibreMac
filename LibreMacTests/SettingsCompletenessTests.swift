// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// A new settable key must fail here, by name, rather than the window
// quietly not having it.

import LibreMacAgentClient
import Testing

@testable import LibreMac

@Suite("Settings completeness")
@MainActor
struct SettingsCompletenessTests {

    @Test("every key the agent accepts has a control")
    func everySettableKeyIsAccountedFor() {
        #expect(
            PreferencesView.settableKeysWithControls == Set(SettableConfigKey.allCases),
            "a key was added to the wire and nothing here noticed")
    }
}

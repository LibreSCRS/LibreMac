// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
@testable import LibreMacShared

@Suite("LocalizedText")
struct LocalizedTextTests {
    @Test("Fallback resolves with placeholder substitution")
    func fallbackSubstitution() {
        let text = LocalizedText(i18nKey: "lm.unknown.key.for.test",
                                 englishFallback: "Hello {name}, you have {count} messages.",
                                 placeholders: ["name": "Ana", "count": "3"])
        let resolved = text.resolve()
        #expect(resolved == "Hello Ana, you have 3 messages.")
    }

    @Test("Strict equality")
    func strictEquality() {
        let a = LocalizedText(i18nKey: "k", englishFallback: "Foo",
                              placeholders: ["x": "1"])
        let b = LocalizedText(i18nKey: "k", englishFallback: "Bar",
                              placeholders: ["x": "1"])
        #expect(a != b)
    }
}

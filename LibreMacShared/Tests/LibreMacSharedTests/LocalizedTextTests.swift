// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
@testable import LibreMacShared

@Suite("LocalizedText")
struct LocalizedTextTests {
    @Test("Fallback resolves with placeholder substitution")
    func fallbackSubstitution() {
        let text = LocalizedText(key: "lm.unknown.key.for.test",
                                 defaultText: "Hello {name}, you have {count} messages.",
                                 placeholders: ["name": "Ana", "count": "3"])
        let resolved = text.resolve()
        #expect(resolved == "Hello Ana, you have 3 messages.")
    }

    /// The fallback path has to render a count too: a key missing from the
    /// catalog falls back to the English default, and that default carries
    /// the count as a format argument, not as a `{count}` token.
    @Test("A count renders into the fallback, ahead of the placeholders")
    func fallbackCountFormatting() {
        let text = LocalizedText(key: "lm.unknown.key.for.test",
                                 defaultText: "The {who} was not correct — %lld attempt(s) left.",
                                 placeholders: ["who": "PIN"])
        #expect(text.resolve(count: 3) == "The PIN was not correct — 3 attempt(s) left.")
        #expect(text.resolve() == "The PIN was not correct — %lld attempt(s) left.")
    }

    @Test("Strict equality")
    func strictEquality() {
        let a = LocalizedText(key: "k", defaultText: "Foo",
                              placeholders: ["x": "1"])
        let b = LocalizedText(key: "k", defaultText: "Bar",
                              placeholders: ["x": "1"])
        #expect(a != b)
    }
}

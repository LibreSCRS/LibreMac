// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
@testable import ts2xcstrings

@Suite("ts2xcstrings")
struct Ts2XcstringsTests {

    @Test("Two .ts files produce one xcstrings with both languages")
    func mergesEnAndSr() throws {
        let bundle = Bundle.module
        let enUrl = try #require(
            bundle.url(forResource: "sample_en", withExtension: "ts", subdirectory: "Fixtures"))
        let srUrl = try #require(
            bundle.url(forResource: "sample_sr", withExtension: "ts", subdirectory: "Fixtures"))

        let catalog = try Ts2Xcstrings.convert(
            sources: [enUrl, srUrl],
            sourceLanguage: "en")

        let cardInserted = try #require(catalog.strings["lc-card-inserted"])
        #expect(cardInserted.localizations["en"]?.stringUnit?.value == "Card inserted")
        #expect(cardInserted.localizations["sr"]?.stringUnit?.value == "Картица убачена")

        let cardRemoved = try #require(catalog.strings["lc-card-removed"])
        #expect(cardRemoved.localizations["sr"]?.stringUnit?.value == "Картица уклоњена")
    }

    @Test("Locale code mapping qt → apple")
    func qtToAppleLocale() {
        #expect(Ts2Xcstrings.appleLocale(forQt: "en_US") == "en")
        #expect(Ts2Xcstrings.appleLocale(forQt: "sr_RS") == "sr")
        #expect(Ts2Xcstrings.appleLocale(forQt: "sr_RS@latin") == "sr-Latn")
    }
}

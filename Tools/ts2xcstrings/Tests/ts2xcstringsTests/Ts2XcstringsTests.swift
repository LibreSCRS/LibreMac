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

    private func fixture(_ name: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: name, withExtension: "ts", subdirectory: "Fixtures"))
    }

    /// The whole point of a plural entry: one string per grammatical number,
    /// keyed by the CLDR category the language's rules name — two for
    /// English, three for Serbian — with Qt's `%n` rewritten to the `%lld`
    /// the catalog's format consumers expect.
    @Test("A numerus message becomes a plural variation per CLDR category")
    func numerusBecomesPluralVariations() throws {
        let catalog = try Ts2Xcstrings.convert(
            sources: [try fixture("plural_en"), try fixture("plural_sr")],
            sourceLanguage: "en")

        let attempts = try #require(catalog.strings["sample-attempts"])

        let en = try #require(attempts.localizations["en"]?.variations?.plural)
        #expect(Set(en.keys) == ["one", "other"])
        #expect(en["one"]?.stringUnit?.value == "%lld attempt left for {who}.")
        #expect(en["other"]?.stringUnit?.value == "%lld attempts left for {who}.")
        #expect(attempts.localizations["en"]?.stringUnit == nil)

        let sr = try #require(attempts.localizations["sr"]?.variations?.plural)
        #expect(Set(sr.keys) == ["one", "few", "other"])
        #expect(sr["one"]?.stringUnit?.value == "Преостао је %lld покушај за {who}.")
        #expect(sr["few"]?.stringUnit?.value == "Преостала су %lld покушаја за {who}.")
        #expect(sr["other"]?.stringUnit?.value == "Преостало је %lld покушаја за {who}.")
    }

    @Test("A plain message in the same file is untouched")
    func plainMessagesAreUnchanged() throws {
        let catalog = try Ts2Xcstrings.convert(
            sources: [try fixture("plural_en"), try fixture("plural_sr")],
            sourceLanguage: "en")

        let plain = try #require(catalog.strings["sample-plain"])
        #expect(plain.localizations["en"]?.stringUnit?.value == "Card inserted")
        #expect(plain.localizations["sr"]?.stringUnit?.value == "Картица убачена")
        #expect(plain.localizations["en"]?.variations == nil)
        #expect(plain.localizations["sr"]?.variations == nil)
    }

    /// The encoded shape is what Xcode reads, and nothing downstream would
    /// notice a plural entry that also carried a `stringUnit` — it would just
    /// quietly win over the forms.
    @Test("The encoded JSON carries variations.plural and no sibling stringUnit")
    func encodedShapeMatchesTheCatalogFormat() throws {
        let catalog = try Ts2Xcstrings.convert(
            sources: [try fixture("plural_en"), try fixture("plural_sr")],
            sourceLanguage: "en")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let attempts = try #require(strings["sample-attempts"] as? [String: Any])
        let localizations = try #require(attempts["localizations"] as? [String: Any])
        let sr = try #require(localizations["sr"] as? [String: Any])
        #expect(sr["stringUnit"] == nil)
        let plural = try #require((sr["variations"] as? [String: Any])?["plural"] as? [String: Any])
        let few = try #require(plural["few"] as? [String: Any])
        let unit = try #require(few["stringUnit"] as? [String: Any])
        #expect(unit["state"] as? String == "translated")
        #expect(unit["value"] as? String == "Преостала су %lld покушаја за {who}.")
    }

    /// A form set that does not match the locale's category count cannot be
    /// mapped — filing three Serbian forms as two, or two as three, silently
    /// hands some count the wrong grammatical number. The conversion stops
    /// instead, which is what makes the pre-build step a gate.
    ///
    /// Pinned to the CASE, not to `ConversionError.self`: the enum's other
    /// case is also thrown from this very call path, so a type-only
    /// expectation stays green if the two refusals are ever swapped — and
    /// a mistranslated form count reported as an unlisted language names the
    /// wrong fix in the message the build prints.
    @Test("A form count that does not match the locale's categories fails loudly")
    func mismatchedFormCountFails() throws {
        do {
            _ = try Ts2Xcstrings.convert(
                sources: [try self.fixture("plural_short_sr")],
                sourceLanguage: "en")
            Issue.record("the conversion did not refuse a two-form Serbian numerus message")
        } catch let error as ConversionError {
            guard case let .numerusFormCountMismatch(id, locale, got, expected) = error else {
                Issue.record("expected numerusFormCountMismatch, got \(error)")
                return
            }
            #expect(id == "sample-attempts")
            #expect(locale == "sr")
            #expect(got == 2)
            #expect(expected == ["one", "few", "other"])
        }
    }

    /// Qt's form order is the language's own; a locale whose category list
    /// this tool does not carry cannot be mapped by counting, so it stops
    /// rather than guessing.
    /// Pinned to the case for the same reason as above: this fixture's three
    /// Russian forms would satisfy a form COUNT check for Serbian, so only
    /// naming the case proves the refusal is the language one.
    @Test("A numerus message in an unlisted locale fails loudly")
    func unlistedPluralLocaleFails() throws {
        do {
            _ = try Ts2Xcstrings.convert(
                sources: [try self.fixture("plural_unknown_lang")],
                sourceLanguage: "en")
            Issue.record("the conversion did not refuse a numerus message in an unlisted locale")
        } catch let error as ConversionError {
            guard case let .unknownPluralLanguage(id, locale) = error else {
                Issue.record("expected unknownPluralLanguage, got \(error)")
                return
            }
            #expect(id == "sample-attempts")
            #expect(locale == "ru")
        }
    }

    @Test("Locale code mapping qt → apple")
    func qtToAppleLocale() {
        #expect(Ts2Xcstrings.appleLocale(forQt: "en_US") == "en")
        #expect(Ts2Xcstrings.appleLocale(forQt: "sr_RS") == "sr")
        #expect(Ts2Xcstrings.appleLocale(forQt: "sr_RS@latin") == "sr-Latn")
    }
}

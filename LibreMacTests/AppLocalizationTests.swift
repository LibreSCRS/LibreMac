// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import LibreMacShared
import Testing

@testable import LibreMac

/// Each test gets its own defaults domain, wiped on entry, so a choice
/// persisted by one test can never decide another one's outcome.
private func isolatedDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}

@Suite("App localization")
@MainActor
struct AppLocalizationTests {

    /// Asserting both directions keeps this independent of whatever language
    /// the machine running it happens to prefer: a test that only checked the
    /// Serbian leg would also pass on a Serbian system with the override
    /// doing nothing at all.
    @Test("an override resolves against the chosen bundle, whatever the system prefers")
    func overrideChangesResolution() {
        let localization = AppLocalization(defaults: isolatedDefaults(#function))

        localization.locale = "en"
        #expect(localization.loc("lc-settings-tab-general", "General") == "General")

        localization.locale = "sr"
        #expect(localization.loc("lc-settings-tab-general", "General") == "Опште")
    }

    @Test("resolving straight through LocalizedText ignores the preference")
    func overrideLeavesDirectResolutionAlone() {
        let localization = AppLocalization(defaults: isolatedDefaults(#function))

        localization.locale = nil
        let systemText = localization.loc("lc-settings-tab-general", "General")

        localization.locale = "sr"

        #expect(
            LocalizedText(key: "lc-settings-tab-general", defaultText: "General").resolve()
                == systemText,
            "the extension shares this type; resolving against .main must not follow a host-only preference"
        )
    }

    /// Placeholder-bearing strings are the ones that used to bypass this
    /// object entirely, which would have left counts and reader names in the
    /// system language while everything around them switched.
    @Test("a placeholder string follows the override and still substitutes")
    func placeholdersFollowTheOverride() {
        let localization = AppLocalization(defaults: isolatedDefaults(#function))

        localization.locale = "en"
        #expect(
            localization.loc("libremac_presence_certs_ready", "{count} certificate(s) ready",
                             placeholders: ["count": "3"]) == "3 certificate(s) ready")

        localization.locale = "sr"
        #expect(
            localization.loc("libremac_presence_certs_ready", "{count} certificate(s) ready",
                             placeholders: ["count": "3"]) == "3 сертификат(а) спремно")
    }

    @Test("an already-built text resolves against the override too")
    func prebuiltTextFollowsTheOverride() {
        let localization = AppLocalization(defaults: isolatedDefaults(#function))
        let text = LocalizedText(
            key: "libremac_error_communication",
            defaultText: "Communication with the card reader failed.")

        localization.locale = "sr"

        #expect(localization.resolve(text) == "Комуникација са читачем картица није успела.")
    }

    /// These ids belong to the desktop client's catalogue, not this repo's:
    /// the settings window reads them out of the merged catalogue, which puts
    /// them outside LibreMac's own completeness gate. If that side ever drops
    /// or renames one, the window quietly renders English while everything
    /// around it is Serbian — and nothing else here would notice.
    @Test("the borrowed settings ids really carry Serbian, not an English fallback")
    func borrowedSettingsIdsAreTranslated() {
        let localization = AppLocalization(defaults: isolatedDefaults(#function))
        localization.locale = "sr"

        for (key, english) in CatalogCompletenessTests.borrowedSettingsIds {
            #expect(localization.loc(key, english) != english, "\(key) fell back to English")
        }
    }

    /// `CatalogCompletenessTests` reads the `.ts` sources; the app reads the
    /// generated `Localizable.xcstrings`. Between them sits a pre-build step
    /// that SILENTLY DOES NOTHING when LibreCelik is not a sibling — which is
    /// exactly the shape of the CI checkout. So a key added to both `.ts`
    /// files and not to the committed catalog passes every other gate here and
    /// renders English to a Serbian user. This is the assertion that closes
    /// that gap for the copy this release added.
    @Test("the cancel copy resolves in Serbian from the shipped catalog")
    func cancelCopyIsTranslated() {
        let localization = AppLocalization(defaults: isolatedDefaults(#function))
        localization.locale = "sr"

        let pairs = [
            ("libremac_credentials_err_cancelled",
             "You closed the prompt, so nothing was changed. Try again when you are ready."),
            ("libremac_settings_err_cancelled",
             "You closed the prompt, so the change was not saved."),
        ]
        for (key, english) in pairs {
            #expect(localization.loc(key, english) != english, "\(key) fell back to English")
        }
    }

    /// Live language switching rests entirely on this: a view body that
    /// resolves a string must register a dependency on the chosen language,
    /// or SwiftUI is never told to redraw it. Caching the resolved bundle in
    /// an observation-ignored property is exactly how that link gets cut,
    /// and nothing else in this suite would notice — every other test reads
    /// the value back directly instead of waiting to be told.
    @Test("resolving a string registers a dependency on the chosen language")
    func resolvingTracksTheLanguage() {
        let localization = AppLocalization(defaults: isolatedDefaults(#function))
        // The change handler is @Sendable, so the flag lives behind a
        // reference rather than being captured as a var.
        let toldAboutChange = ChangeFlag()

        withObservationTracking {
            _ = localization.loc("lc-settings-tab-general", "General")
        } onChange: {
            toldAboutChange.fired = true
        }

        localization.locale = "sr"

        #expect(
            toldAboutChange.fired,
            "a view resolving a string is never redrawn on a language change")
    }

    /// Serbian has three grammatical numbers where English has two, and the
    /// rule is not "1 versus the rest": 21 takes the same form as 1, while 11
    /// takes the same form as 5. A sentence that carries the count therefore
    /// cannot be assembled by substituting a number into one template — the
    /// count has to reach the formatter, and the formatter has to be told
    /// which language's rules to apply. This asserts the RENDERED sentences,
    /// because every part of that chain (catalog shape, format-before-
    /// substitute order, the locale the rules come from) is invisible in the
    /// catalog alone.
    @Test("the attempts sentence takes the Serbian form each count calls for")
    func attemptsSentenceFollowsSerbianPluralRules() {
        let localization = AppLocalization(defaults: isolatedDefaults(#function))
        localization.locale = "sr"

        let expected: [Int: String] = [
            1: "ПИН није тачан — преостао је 1 покушај.",
            2: "ПИН није тачан — преостала су 2 покушаја.",
            5: "ПИН није тачан — преостало је 5 покушаја.",
            11: "ПИН није тачан — преостало је 11 покушаја.",
            21: "ПИН није тачан — преостао је 21 покушај.",
        ]
        for (count, sentence) in expected.sorted(by: { $0.key < $1.key }) {
            let rendered = localization.loc(
                "libremac_credentials_outcome_invalidPin_attributed",
                "The {who} was not correct — %lld attempt(s) left.",
                placeholders: ["who": "ПИН"],
                count: count)
            #expect(rendered == sentence, "count \(count) rendered: \(rendered)")
            #expect(!rendered.contains("{who}"), "count \(count) left {who} unsubstituted")
        }
    }

    /// The English side of the same key: two forms, and the singular is the
    /// one a user hits on their last attempt.
    @Test("the attempts sentence takes the English singular for one attempt")
    func attemptsSentenceFollowsEnglishPluralRules() {
        let localization = AppLocalization(defaults: isolatedDefaults(#function))
        localization.locale = "en"

        let expected: [Int: String] = [
            1: "The PIN was not correct — 1 attempt left.",
            2: "The PIN was not correct — 2 attempts left.",
            21: "The PIN was not correct — 21 attempts left.",
        ]
        for (count, sentence) in expected.sorted(by: { $0.key < $1.key }) {
            let rendered = localization.loc(
                "libremac_credentials_outcome_invalidPin_attributed",
                "The {who} was not correct — %lld attempt(s) left.",
                placeholders: ["who": "PIN"],
                count: count)
            #expect(rendered == sentence, "count \(count) rendered: \(rendered)")
        }
    }

    @Test("an unknown key still falls back rather than resolving to nothing")
    func unknownKeyFallsBack() {
        let localization = AppLocalization(defaults: isolatedDefaults(#function))

        localization.locale = "sr"

        #expect(localization.loc("no-such-key-anywhere", "Fallback") == "Fallback")
    }

    @Test("a chosen language outlives the object that chose it")
    func choiceSurvivesRelaunch() {
        let name = #function
        let localization = AppLocalization(defaults: isolatedDefaults(name))

        localization.locale = "sr"
        #expect(AppLocalization(defaults: UserDefaults(suiteName: name)!).locale == "sr")

        localization.locale = nil
        #expect(AppLocalization(defaults: UserDefaults(suiteName: name)!).locale == nil)
    }
}

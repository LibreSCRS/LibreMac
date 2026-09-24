// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Completeness gate for the LibreMac-owned `.ts` catalogs
// (`LibreMac/Resources/i18n/LibreMac_en.ts` + `LibreMac_sr_RS.ts`) — the
// sources `Localizable.xcstrings` is regenerated from (together with the
// LibreCelik pair) at pre-build time. Three invariants:
//   1. en and sr carry the SAME id set (a key translated in one locale
//      only would silently render its fallback in the other);
//   2. every `libremac_credentials_*` id the credentials surface renders
//      (CredentialsView + ErrorCopy) exists in BOTH, plus the agent
//      guidance keys the flows actually emit and every `prompter_*` id the
//      credential prompter looks up;
//   3. no LibreMac-owned id enters the `lc-` namespace — ts2xcstrings
//      merges per-locale values last-writer-wins, so id-set disjointness
//      with LibreCelik is the real lossless-regeneration protection.

import Foundation
import Testing

@Suite("Catalog completeness")
struct CatalogCompletenessTests {

    // MARK: - Catalog locations (resolved from this source file)

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CatalogCompletenessTests.swift
        .deletingLastPathComponent()  // LibreMacTests/
    private static let enCatalog =
        repoRoot
        .appendingPathComponent("LibreMac/Resources/i18n/LibreMac_en.ts")
    private static let srCatalog =
        repoRoot
        .appendingPathComponent("LibreMac/Resources/i18n/LibreMac_sr_RS.ts")
    /// The generated catalog the app actually reads — the `.ts` pair above
    /// is only its source.
    private static let stringCatalog =
        repoRoot
        .appendingPathComponent("LibreMac/Resources/Localizable.xcstrings")

    // MARK: - Reference lists

    /// Every `libremac_credentials_*` id the credentials surface consumes.
    /// Kept literal so a key dropped from a catalog fails HERE, not as a
    /// silently-untranslated string at render time.
    private static let credentialIds: Set<String> = [
        // menu / window
        "libremac_credentials_menu",
        "libremac_credentials_title",
        // per-kind labels
        "libremac_credentials_kind_user",
        "libremac_credentials_kind_sign",
        "libremac_credentials_kind_puk",
        "libremac_credentials_kind_can",
        "libremac_credentials_kind_unknown",
        // per-state labels
        "libremac_credentials_state_unknown",
        "libremac_credentials_state_transport",
        "libremac_credentials_state_operational",
        "libremac_credentials_state_needs_change",
        "libremac_credentials_state_blocked",
        // action titles
        "libremac_credentials_action_change",
        "libremac_credentials_action_unblock",
        "libremac_credentials_action_activate_pin",
        "libremac_credentials_action_activate_key",
        "libremac_credentials_action_cancel",
        // unblock confirm sheet
        "libremac_credentials_unblock_title",
        "libremac_credentials_unblock_prompt_notice",
        "libremac_credentials_unblock_budget",
        "libremac_credentials_unblock_budget_nomax",
        "libremac_credentials_unblock_continue",
        // counters
        "libremac_credentials_retries_left",
        "libremac_credentials_retries_max",
        "libremac_credentials_uses_left",
        "libremac_credentials_uses_max",
        // Outcome copy — every wire token EXCEPT userCancelled, which
        // renders no label at all (as in LibreKDE) and so owns no key.
        "libremac_credentials_outcome_unspecified",
        "libremac_credentials_outcome_ok",
        "libremac_credentials_outcome_missingFields",
        "libremac_credentials_outcome_invalidPin",
        "libremac_credentials_outcome_blocked",
        "libremac_credentials_outcome_pluginError",
        "libremac_credentials_outcome_unsupported",
        "libremac_credentials_outcome_keyActivationFailed",
        "libremac_credentials_outcome_cardRemoved",
        // attributed invalid-PIN variant (retries-aware)
        "libremac_credentials_outcome_invalidPin_attributed",
        // sync-error copy (ErrorCopy.localizedText(for: SyncError))
        "libremac_credentials_err_unsupported",
        "libremac_credentials_err_not_authorized",
        "libremac_credentials_err_rate_limited",
        "libremac_credentials_err_unknown_credential",
        "libremac_credentials_err_invalid_request",
        "libremac_credentials_err_cancelled",
    ]

    /// The guidance keys the agent's flows actually emit (grepped from the
    /// shipping quirk table, never minted client-side); the client owns
    /// their translations.
    private static let guidanceIds: Set<String> = [
        "librescrs.pin.blocked.issuer",
        "librescrs.pin.keyActivation.issuer",
        // The only retry `lastError` the agent emits on the credential path,
        // resolved by the prompter under the wire key itself. Listed here
        // rather than left to the id-set invariant because that invariant
        // stays green if the key is dropped from BOTH catalogs — which is
        // exactly the shape that leaves a Serbian dialog with an English
        // sentence in it.
        "librescrs.error.preRead.authFailed",
    ]

    /// The reader-picker ids the multi-reader UI renders.
    private static let readerPickerIds: Set<String> = [
        "libremac_reader_picker_title",
        "libremac_reader_iface_contact",
        "libremac_reader_iface_contactless",
    ]

    /// Every `prompter_*` id the agent-owned credential prompter reaches, from
    /// both sides it reaches them by: the ids `PromptWindow.mm` /
    /// `ConfirmAuthorizer.mm` look up directly, and the five trust sentences the
    /// agent names on the wire as a `descriptionKey` for the panel to look up.
    /// Listed because the id-set invariant alone stays green if a key is
    /// dropped from BOTH catalogs — which is exactly the shape that leaves a
    /// Serbian panel showing an English sentence.
    private static let prompterIds: Set<String> = [
        // window titles
        "prompter_title_can",
        "prompter_title_mrz",
        "prompter_title_pin",
        "prompter_title_change_pin",
        // headings
        "prompter_heading_can",
        "prompter_heading_mrz",
        "prompter_heading_pin",
        "prompter_heading_change_pin",
        // the change panel's three field captions
        "prompter_label_current_pin",
        "prompter_label_new_pin",
        "prompter_label_confirm_pin",
        // buttons
        "prompter_button_cancel",
        "prompter_button_ok",
        // retry lines
        "prompter_retry_generic",
        "prompter_retry_rejected",
        // the framing above the entry field
        "prompter_requested_by",
        "prompter_document",
        "prompter_reader",
        "prompter_reader_contact",
        "prompter_reader_contactless",
        // the batch-sign consent list
        "prompter_batch_documents",
        "prompter_batch_more",
        // the device-owner confirmation
        "prompter_confirm_requested_by",
        // the trust sentences the agent sends as a descriptionKey
        "prompter_trust_import",
        "prompter_trust_forget",
        "prompter_trust_tsa",
        "prompter_trust_tsl",
        "prompter_trust_generic",
    ]

    /// The refusal sentences the settings window renders when the agent
    /// declines a write. Listed because the id-set invariant alone stays
    /// green if a key is dropped from BOTH catalogs — which would leave the
    /// window quietly showing its English fallback in Serbian.
    private static let settingsIds: Set<String> = [
        "libremac_settings_err_save_failed",
        "libremac_settings_err_not_authorized",
        "libremac_settings_err_invalid_value",
        "libremac_settings_err_read_only",
        "libremac_settings_err_unknown_key",
        "libremac_settings_err_cancelled",
        "libremac_settings_language_system",
        "libremac_settings_browse",
        "libremac_settings_agent_unavailable",
        "libremac_settings_restore_default",
        "libremac_settings_default_reason",
        "libremac_settings_default_location",
        "libremac_settings_advisory_timestamping_applies",
        "libremac_settings_advisory_no_tsa",
        "libremac_settings_tab_advanced",
        "libremac_settings_plugin_dir",
        "libremac_settings_aia_cache_dir",
        "libremac_settings_path_unset",
        "libremac_settings_agent_owned_paths",
        "libremac_settings_agent_unavailable_title",
        "libremac_settings_output_footer_sandboxed",
        "libremac_settings_output_placeholder",
        "libremac_settings_signing_footer",
        "libremac_settings_action_cancel",
        "libremac_settings_action_add",
        "libremac_settings_trust_remove",
        "libremac_settings_trust_clear",
        "libremac_settings_trust_clear_title",
        "libremac_settings_trust_clear_confirm",
        "libremac_settings_trust_clear_msg",
        "libremac_settings_trust_eager",
        "libremac_settings_trust_no_tsa",
        "libremac_settings_trust_no_lists",
        "libremac_settings_last_tsa",
        "libremac_settings_trust_add_tsa",
        "libremac_settings_trust_add_tsa_title",
        "libremac_settings_trust_anchors",
        "libremac_settings_trust_no_anchors",
        "libremac_settings_trust_anchors_held",
        "libremac_settings_trust_anchor_issuers",
        "libremac_settings_trust_anchors_accepted",
        "libremac_settings_trust_anchor_signer",
        "libremac_settings_trust_anchor_signer_pinned",
        "libremac_settings_trust_anchor_signer_unpinned",
        "libremac_settings_trust_anchors_no_replay_refusal",
        "libremac_settings_trust_anchors_unreadable",
        "libremac_settings_trust_anchors_signed",
    ]

    /// Ids the settings window renders but does NOT own — they come from the
    /// desktop client's catalogue through the merged one. Listed here only so
    /// the set has a home; the assertion that they still resolve to Serbian
    /// lives with the localization tests, since this gate reads this repo's
    /// catalogues and cannot see them.
    static let borrowedSettingsIds: [(String, String)] = [
        ("lc-settings-tab-general", "General"),
        ("lc-settings-tab-signing", "Signing"),
        ("lc-settings-language", "Language:"),
        ("lc-settings-default-output", "Default output folder:"),
        ("lc-settings-default-level", "Default level:"),
        ("lc-settings-cache-dir", "Cache folder:"),
        ("lc-settings-tab-trust", "Trust"),
        ("lc-settings-tsa-servers", "Timestamping authorities"),
        ("lc-settings-tl-servers", "Trusted lists"),
        ("lc-settings-tl-add-item", "Add…"),
        ("lc-settings-tl-add-title", "Add a trusted list"),
        ("lc-settings-tl-type", "List of lists"),
        ("lc-settings-invalid-url-msg", "Enter a full http or https address."),
    ]

    // MARK: - Parsing

    /// All `<message id="...">` ids of a qtTrId-style `.ts` catalog, in
    /// file order.
    private static func ids(of url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: "<message id=\"([^\"]+)\"[^>]*>")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).map { match in
            String(text[Range(match.range(at: 1), in: text)!])
        }
    }

    /// The translated bodies of every `<message id="...">`, keyed by id — one
    /// entry per `<numerusform>` for a numerus message, a single entry for a
    /// plain one.
    ///
    /// The split is what makes every assertion below a PER-FORM assertion. A
    /// numerus message's forms are separate sentences, so with the whole
    /// `<translation>` body as one string a `contains` check passes the
    /// moment ANY one form still carries the token: drop `{who}` from the
    /// Serbian `few` form alone and the `one` form keeps the check green,
    /// while every count from 2 to 4 renders a sentence that has stopped
    /// saying which credential it is about.
    private static func translationForms(of url: URL) throws -> [String: [String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(
            pattern: "<message id=\"([^\"]+)\"[^>]*>.*?<translation>(.*?)</translation>",
            options: [.dotMatchesLineSeparators])
        let formPattern = try NSRegularExpression(
            pattern: "<numerusform>(.*?)</numerusform>",
            options: [.dotMatchesLineSeparators])
        let range = NSRange(text.startIndex..., in: text)
        var out: [String: [String]] = [:]
        for match in pattern.matches(in: text, range: range) {
            let id = String(text[Range(match.range(at: 1), in: text)!])
            let body = String(text[Range(match.range(at: 2), in: text)!])
            let bodyRange = NSRange(body.startIndex..., in: body)
            let forms = formPattern.matches(in: body, range: bodyRange).map { formMatch in
                String(body[Range(formMatch.range(at: 1), in: body)!])
            }
            out[id] = forms.isEmpty ? [body] : forms
        }
        return out
    }

    // MARK: - Invariants

    @Test("en and sr catalogs carry the same id set, without duplicates")
    func idSetsAreEqual() throws {
        let en = try Self.ids(of: Self.enCatalog)
        let sr = try Self.ids(of: Self.srCatalog)
        #expect(!en.isEmpty)
        #expect(en.count == Set(en).count, "duplicate ids in the en catalog")
        #expect(sr.count == Set(sr).count, "duplicate ids in the sr catalog")
        let missingInSr = Set(en).subtracting(sr)
        let missingInEn = Set(sr).subtracting(en)
        #expect(missingInSr.isEmpty, "ids missing in sr: \(missingInSr.sorted())")
        #expect(missingInEn.isEmpty, "ids missing in en: \(missingInEn.sorted())")
    }

    /// Two outcome sentences name the credential they are about, matching
    /// LibreKDE's `CredentialText`. The name arrives as a `{who}`
    /// placeholder, so a translation that drops it still renders — as a
    /// sentence that has quietly stopped saying which credential failed.
    @Test("the attributed outcome strings keep their {who} placeholder in both locales")
    func attributedOutcomesKeepTheirPlaceholder() throws {
        let attributed = [
            "libremac_credentials_outcome_invalidPin",
            "libremac_credentials_outcome_blocked",
            "libremac_credentials_outcome_invalidPin_attributed",
        ]
        for (locale, url) in [("en", Self.enCatalog), ("sr", Self.srCatalog)] {
            let table = try Self.translationForms(of: url)
            for id in attributed {
                let forms = try #require(table[id], "\(id) absent from \(locale)")
                #expect(!forms.isEmpty, "\(locale) \(id) has no translated body")
                for (index, form) in forms.enumerated() {
                    #expect(
                        form.contains("{who}"),
                        "\(locale) \(id) form \(index) lost {who}: \(form)")
                }
            }
        }
    }

    /// Named `{placeholder}` tokens a translation string carries, e.g.
    /// `{who}` / `{count}` / `{level}`.
    private static func placeholders(in text: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: "\\{([a-zA-Z_][a-zA-Z0-9_]*)\\}")
        let range = NSRange(text.startIndex..., in: text)
        return Set(
            pattern.matches(in: text, range: range).map { match in
                String(text[Range(match.range(at: 1), in: text)!])
            })
    }

    /// Generic sibling of `attributedOutcomesKeepTheirPlaceholder` above:
    /// rather than hand-picking ids, this checks every id BOTH catalogs
    /// carry — a translation that drops (or renames) a `{placeholder}` still
    /// parses as valid `.ts` XML, so nothing else here would catch it before
    /// it silently stops filling in at render time.
    @Test("every shared id keeps the same named placeholders in both locales")
    func placeholdersMatchAcrossLocales() throws {
        let en = try Self.translationForms(of: Self.enCatalog)
        let sr = try Self.translationForms(of: Self.srCatalog)
        let sharedIds = Set(en.keys).intersection(sr.keys)
        #expect(!sharedIds.isEmpty)
        for id in sharedIds.sorted() {
            // Compared per FORM against the en source's first form: the two
            // locales need not carry the same NUMBER of forms (en has two
            // plural categories, sr three), but every form of either is the
            // same sentence about the same values and must fill in the same
            // tokens. Comparing a per-message union instead would let one
            // form of three drop a token unnoticed.
            let enForms = try (en[id] ?? []).map { try Self.placeholders(in: $0) }
            let srForms = try (sr[id] ?? []).map { try Self.placeholders(in: $0) }
            let expected = try #require(enForms.first, "\(id): no en body")
            for (index, found) in enForms.enumerated() {
                #expect(
                    found == expected,
                    "\(id): en form \(index) has \(found.sorted()), en form 0 has \(expected.sorted())")
            }
            for (index, found) in srForms.enumerated() {
                #expect(
                    found == expected,
                    "\(id): sr form \(index) has \(found.sorted()), en has \(expected.sorted())")
            }
        }
    }

    @Test("every credentials id the UI renders exists in both catalogs")
    func credentialIdsAreComplete() throws {
        let en = Set(try Self.ids(of: Self.enCatalog))
        let sr = Set(try Self.ids(of: Self.srCatalog))
        let missingInEn = Self.credentialIds.subtracting(en)
        let missingInSr = Self.credentialIds.subtracting(sr)
        #expect(missingInEn.isEmpty, "missing in en: \(missingInEn.sorted())")
        #expect(missingInSr.isEmpty, "missing in sr: \(missingInSr.sorted())")
    }

    @Test("every reader-picker id exists in both catalogs")
    func readerPickerIdsAreComplete() throws {
        let en = Set(try Self.ids(of: Self.enCatalog))
        let sr = Set(try Self.ids(of: Self.srCatalog))
        #expect(Self.readerPickerIds.subtracting(en).isEmpty)
        #expect(Self.readerPickerIds.subtracting(sr).isEmpty)
    }

    @Test("every prompter id exists in both catalogs")
    func prompterIdsAreComplete() throws {
        let en = Set(try Self.ids(of: Self.enCatalog))
        let sr = Set(try Self.ids(of: Self.srCatalog))
        let missingInEn = Self.prompterIds.subtracting(en)
        let missingInSr = Self.prompterIds.subtracting(sr)
        #expect(missingInEn.isEmpty, "missing in en: \(missingInEn.sorted())")
        #expect(missingInSr.isEmpty, "missing in sr: \(missingInSr.sorted())")
    }

    /// The prompter's own strings are rendered by AppKit's `stringWithFormat:`,
    /// not by a named-placeholder substitution, so a translation that drops its
    /// `%@` silently loses the value (the reader's model, the requesting app's
    /// name, the count of documents the list left out) and one that doubles it
    /// reads a vararg that was never passed. Neither shows up as a bad
    /// translation until it is on screen — or, for the doubled one, until it
    /// crashes.
    @Test("the prompter's formatted strings carry exactly one %@ in both locales")
    func prompterFormatStringsKeepOnePlaceholder() throws {
        let formatted = [
            "prompter_reader",
            "prompter_confirm_requested_by",
            "prompter_batch_more",
        ]
        for (locale, url) in [("en", Self.enCatalog), ("sr", Self.srCatalog)] {
            let table = try Self.translationForms(of: url)
            for id in formatted {
                let forms = try #require(table[id], "\(id) absent from \(locale)")
                for form in forms {
                    let count = form.components(separatedBy: "%@").count - 1
                    #expect(
                        count == 1,
                        "\(locale) \(id) carries \(count) %@, expected exactly 1: \(form)")
                }
            }
        }
    }

    /// Every id the sign window and the signing coordinator render, typed
    /// paths included.
    private static let signIds: Set<String> = [
        "libremac_sign_title",
        "libremac_sign_button",
        "libremac_sign_action",
        "libremac_sign_input_label",
        "libremac_sign_output_label",
        "libremac_sign_typed_paths_hint",
        "libremac_sign_dest_fallback_downloads",
        "libremac_sign_not_permitted",
        "libremac_sign_path_not_absolute",
        "libremac_sign_no_card",
        "libremac_sign_dest_is_input",
        "libremac_sign_dest_not_a_file",
        "libremac_sign_replace_prompt",
        "libremac_sign_replace",
        "libremac_settings_action_cancel",
        "libremac_sign_input_unreadable",
        "libremac_sign_write_failed",
        "libremac_sign_no_artifact",
        "libremac_sign_pick_input",
        "libremac_sign_pick_output",
        "libremac_sign_preparing",
        "libremac_sign_confirm",
        "libremac_sign_working",
        "libremac_sign_done",
        "libremac_sign_done_level",
        "libremac_sign_chain_incomplete",
        "libremac_sign_another",
        "libremac_sign_retry",
    ]

    @Test("every sign window id exists in both catalogs")
    func signIdsAreComplete() throws {
        let en = Set(try Self.ids(of: Self.enCatalog))
        let sr = Set(try Self.ids(of: Self.srCatalog))
        #expect(Self.signIds.subtracting(en).isEmpty, "missing in en: \(Self.signIds.subtracting(en))")
        #expect(Self.signIds.subtracting(sr).isEmpty, "missing in sr: \(Self.signIds.subtracting(sr))")
    }

    @Test("every settings refusal id exists in both catalogs")
    func settingsIdsAreComplete() throws {
        let en = Set(try Self.ids(of: Self.enCatalog))
        let sr = Set(try Self.ids(of: Self.srCatalog))
        #expect(Self.settingsIds.subtracting(en).isEmpty)
        #expect(Self.settingsIds.subtracting(sr).isEmpty)
    }

    @Test("the agent's emitted guidance keys are translated in both catalogs")
    func guidanceIdsAreComplete() throws {
        let en = Set(try Self.ids(of: Self.enCatalog))
        let sr = Set(try Self.ids(of: Self.srCatalog))
        let missingInEn = Self.guidanceIds.subtracting(en)
        let missingInSr = Self.guidanceIds.subtracting(sr)
        #expect(missingInEn.isEmpty, "missing in en: \(missingInEn.sorted())")
        #expect(missingInSr.isEmpty, "missing in sr: \(missingInSr.sorted())")
    }

    // MARK: - Plural entries

    /// The CLDR plural categories each shipped language needs, in the order
    /// CLDR lists them. A form set that is not exactly this renders the wrong
    /// grammatical number for some count and nothing else notices: the
    /// sentence is well-formed, just wrong about 21.
    private static let pluralCategories: [String: Set<String>] = [
        "en": ["one", "other"],
        "sr": ["one", "few", "other"],
    ]

    /// Reads the generated catalog and returns, per key, the plural form set
    /// each locale carries. Keys without plural forms are absent.
    private static func pluralForms() throws -> [String: [String: [String: String]]] {
        let data = try Data(contentsOf: stringCatalog)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        var out: [String: [String: [String: String]]] = [:]
        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any]
            else { continue }
            for (locale, localization) in localizations {
                guard let localization = localization as? [String: Any],
                      let variations = localization["variations"] as? [String: Any],
                      let plural = variations["plural"] as? [String: Any]
                else { continue }
                var forms: [String: String] = [:]
                for (category, unit) in plural {
                    guard let unit = unit as? [String: Any],
                          let stringUnit = unit["stringUnit"] as? [String: Any],
                          let value = stringUnit["value"] as? String
                    else { continue }
                    forms[category] = value
                }
                out[key, default: [:]][locale] = forms
            }
        }
        return out
    }

    /// The count-bearing sentence is rendered by the plural formatter, not by
    /// `{count}` substitution: the formatter picks a form by the language's
    /// rules, so a Serbian entry that drops `few` falls back to the form
    /// Apple finds — and the sentence reads wrong only for the counts that
    /// needed the missing form, which is as invisible as a translation bug
    /// gets.
    @Test("every plural entry carries the full form set its language needs, with %lld in each")
    func pluralEntriesCarryEveryForm() throws {
        let plurals = try Self.pluralForms()
        #expect(!plurals.isEmpty, "no plural entry in the generated catalog at all")
        #expect(
            plurals["libremac_credentials_outcome_invalidPin_attributed"] != nil,
            "the attempts sentence is not a plural entry")
        for (key, perLocale) in plurals.sorted(by: { $0.key < $1.key }) {
            for locale in Self.pluralCategories.keys.sorted() {
                let forms = try #require(
                    perLocale[locale], "\(key): plural in \(perLocale.keys.sorted()) but not \(locale)")
                #expect(
                    Set(forms.keys) == Self.pluralCategories[locale]!,
                    "\(key) \(locale): forms \(forms.keys.sorted()), expected \(Self.pluralCategories[locale]!.sorted())")
                for (category, value) in forms.sorted(by: { $0.key < $1.key }) {
                    #expect(
                        value.contains("%lld"),
                        "\(key) \(locale) \(category) has no count argument: \(value)")
                }
            }
        }
    }

    @Test("no LibreMac-owned id enters the LibreCelik lc- namespace")
    func noIdCollidesWithLibreCelik() throws {
        for url in [Self.enCatalog, Self.srCatalog] {
            for id in try Self.ids(of: url) where id.hasPrefix("lc-") {
                Issue.record(
                    "\(id) in \(url.lastPathComponent) collides with the LibreCelik namespace")
            }
        }
    }
}

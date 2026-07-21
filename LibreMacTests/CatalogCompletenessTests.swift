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
//      guidance keys the flows actually emit;
//   3. no LibreMac-owned id enters the `lc-` namespace — ts2xcstrings
//      merges per-locale values last-writer-wins, so id-set disjointness
//      with LibreCelik is the real lossless-regeneration protection.

import Foundation
import Testing

@Suite("Catalog completeness")
struct CatalogCompletenessTests {

    // MARK: - Catalog locations (resolved from this source file)

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CatalogCompletenessTests.swift
        .deletingLastPathComponent() // LibreMacTests/
    private static let enCatalog = repoRoot
        .appendingPathComponent("LibreMac/Resources/i18n/LibreMac_en.ts")
    private static let srCatalog = repoRoot
        .appendingPathComponent("LibreMac/Resources/i18n/LibreMac_sr_RS.ts")

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
        // counters
        "libremac_credentials_retries_left",
        "libremac_credentials_retries_max",
        "libremac_credentials_uses_left",
        "libremac_credentials_uses_max",
        // outcome copy (all ten wire tokens)
        "libremac_credentials_outcome_unspecified",
        "libremac_credentials_outcome_ok",
        "libremac_credentials_outcome_userCancelled",
        "libremac_credentials_outcome_missingFields",
        "libremac_credentials_outcome_invalidPin",
        "libremac_credentials_outcome_blocked",
        "libremac_credentials_outcome_pluginError",
        "libremac_credentials_outcome_unsupported",
        "libremac_credentials_outcome_keyActivationFailed",
        "libremac_credentials_outcome_cardRemoved",
        // sync-error copy (ErrorCopy.localizedText(for: SyncError))
        "libremac_credentials_err_unsupported",
        "libremac_credentials_err_not_authorized",
        "libremac_credentials_err_rate_limited",
        "libremac_credentials_err_unknown_credential",
        "libremac_credentials_err_invalid_request",
    ]

    /// The guidance keys the agent's flows actually emit (grepped from the
    /// shipping quirk table, never minted client-side); the client owns
    /// their translations.
    private static let guidanceIds: Set<String> = [
        "librescrs.pin.blocked.issuer",
        "librescrs.pin.keyActivation.issuer",
    ]

    // MARK: - Parsing

    /// All `<message id="...">` ids of a qtTrId-style `.ts` catalog, in
    /// file order.
    private static func ids(of url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: "<message id=\"([^\"]+)\">")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).map { match in
            String(text[Range(match.range(at: 1), in: text)!])
        }
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

    @Test("every credentials id the UI renders exists in both catalogs")
    func credentialIdsAreComplete() throws {
        let en = Set(try Self.ids(of: Self.enCatalog))
        let sr = Set(try Self.ids(of: Self.srCatalog))
        let missingInEn = Self.credentialIds.subtracting(en)
        let missingInSr = Self.credentialIds.subtracting(sr)
        #expect(missingInEn.isEmpty, "missing in en: \(missingInEn.sorted())")
        #expect(missingInSr.isEmpty, "missing in sr: \(missingInSr.sorted())")
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

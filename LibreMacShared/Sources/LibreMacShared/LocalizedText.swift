// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Swift wrapper around `LibreSCRS::LocalizedText`.
///
/// Mirrors the C++ struct's three-field shape: i18n key, English fallback,
/// and `{name}` placeholder substitutions. Equality is strict structural
/// equality (matching the C++ side's `operator==` definition).
public struct LocalizedText: Equatable, Sendable {
    public let key: String
    public let defaultText: String
    public let placeholders: [String: String]

    public init(key: String, defaultText: String,
                placeholders: [String: String] = [:]) {
        self.key = key
        self.defaultText = defaultText
        self.placeholders = placeholders
    }

    /// Resolve the text against the LibreMac string catalog, falling back to
    /// `defaultText` if the key is not found. Placeholders are substituted
    /// by literal string replacement of `{name}` tokens in either the resolved
    /// or fallback template.
    ///
    /// `count` selects a plural form for a key whose catalog entry carries
    /// one. The two steps are ordered and cannot be swapped: what the catalog
    /// hands back for a plural key is not the sentence but a format carrying
    /// the variants, and only running it through `String(format:)` FIRST
    /// yields text with `{name}` tokens in it at all. Substituting first
    /// leaves the format untouched and the count unrendered.
    public func resolve(bundle: Bundle = .main, table: String = "Localizable",
                        count: Int? = nil) -> String {
        let template = NSLocalizedString(key, tableName: table, bundle: bundle,
                                         value: defaultText, comment: "")
        var output = count.map {
            String(format: template, locale: Self.pluralLocale(for: bundle), $0)
        } ?? template
        for (k, v) in placeholders {
            output = output.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return output
    }

    /// The locale whose plural rules apply to text taken out of `bundle`.
    ///
    /// The rule is chosen by the locale argument, never by the bundle the
    /// string came from, so a Serbian sentence formatted under the machine's
    /// locale follows the machine's grammar: with English rules 21 reads
    /// `21 покушаја` instead of `21 покушај`, and the mistake only appears on
    /// a machine whose language is not the app's. Measured, hence the
    /// derivation below rather than `preferredLocalizations` alone: a bundle
    /// opened on an `xx.lproj` directory — which is exactly what a language
    /// override hands us — reports `preferredLocalizations == ["en"]`
    /// whatever language it holds, so its own directory name is the only
    /// thing that names the language it carries.
    private static func pluralLocale(for bundle: Bundle) -> Locale {
        let name = bundle.bundleURL.lastPathComponent
        if name.hasSuffix(".lproj") {
            return Locale(identifier: String(name.dropLast(".lproj".count)))
        }
        if let preferred = bundle.preferredLocalizations.first {
            return Locale(identifier: preferred)
        }
        return .current
    }
}

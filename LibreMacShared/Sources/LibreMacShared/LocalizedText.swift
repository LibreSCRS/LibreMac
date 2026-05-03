// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Swift wrapper around `LibreSCRS::Auth::LocalizedText`.
///
/// Mirrors the C++ struct's three-field shape: i18n key, English fallback,
/// and `{name}` placeholder substitutions. Equality is strict structural
/// equality (matching the C++ side's `operator==` definition).
public struct LocalizedText: Equatable, Sendable {
    public let i18nKey: String
    public let englishFallback: String
    public let placeholders: [String: String]

    public init(i18nKey: String, englishFallback: String,
                placeholders: [String: String] = [:]) {
        self.i18nKey = i18nKey
        self.englishFallback = englishFallback
        self.placeholders = placeholders
    }

    /// Resolve the text against the LibreMac string catalog, falling back to
    /// `englishFallback` if the key is not found. Placeholders are substituted
    /// by literal string replacement of `{name}` tokens in either the resolved
    /// or fallback template.
    public func resolve(bundle: Bundle = .main, table: String = "Localizable") -> String {
        let template = NSLocalizedString(i18nKey, tableName: table, bundle: bundle,
                                         value: englishFallback, comment: "")
        var output = template
        for (k, v) in placeholders {
            output = output.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return output
    }
}

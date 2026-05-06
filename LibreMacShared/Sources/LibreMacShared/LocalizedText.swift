// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Swift wrapper around `LibreSCRS::Auth::LocalizedText`.
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
    public func resolve(bundle: Bundle = .main, table: String = "Localizable") -> String {
        let template = NSLocalizedString(key, tableName: table, bundle: bundle,
                                         value: defaultText, comment: "")
        var output = template
        for (k, v) in placeholders {
            output = output.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return output
    }
}

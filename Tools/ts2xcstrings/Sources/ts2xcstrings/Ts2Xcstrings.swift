// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

// MARK: - Apple String Catalog model (subset)

public struct StringUnit: Codable, Sendable {
    public var state: String  // "translated" | "needs_review" | "stale"
    public var value: String
}

/// One locale's value for a key: either a single string, or — for a key the
/// `.ts` source marks `numerus="yes"` — one string per plural category.
public struct Localization: Codable, Sendable {
    public var stringUnit: StringUnit?
    public var variations: PluralVariations?

    public init(stringUnit: StringUnit? = nil, variations: PluralVariations? = nil) {
        self.stringUnit = stringUnit
        self.variations = variations
    }
}

/// The catalog's plural container: CLDR category (`one` / `few` / `other`)
/// to the string that category renders.
public struct PluralVariations: Codable, Sendable {
    public var plural: [String: Localization]

    public init(plural: [String: Localization]) {
        self.plural = plural
    }
}

public struct StringEntry: Codable, Sendable {
    public var comment: String?
    public var localizations: [String: Localization]
}

public struct StringCatalog: Codable, Sendable {
    public var sourceLanguage: String
    public var strings: [String: StringEntry]
    public let version: String

    public init(sourceLanguage: String) {
        self.sourceLanguage = sourceLanguage
        self.strings = [:]
        self.version = "1.0"
    }
}

// MARK: - Conversion

public enum ConversionError: LocalizedError {
    case unknownPluralLanguage(id: String, locale: String)
    case numerusFormCountMismatch(id: String, locale: String, got: Int, expected: [String])

    public var errorDescription: String? {
        switch self {
        case let .unknownPluralLanguage(id, locale):
            return "\(id): no plural category list for locale '\(locale)'; "
                + "add it to pluralCategoriesByLocale before translating a numerus message into it"
        case let .numerusFormCountMismatch(id, locale, got, expected):
            return "\(id) [\(locale)]: \(got) numerusform(s) for \(expected.count) plural "
                + "categories \(expected)"
        }
    }
}

public enum Ts2Xcstrings {
    /// The CLDR plural categories each shipped locale needs, in CLDR's
    /// canonical order — the order Qt writes `<numerusform>` elements in, so
    /// the Nth form is the Nth category HERE. The list is per locale and
    /// deliberately short: the two counts agree only by language. Russian, to
    /// name the nearest example, has three Qt forms covering `one`/`few`/
    /// `many` with CLDR's `other` reserved for fractions, so reading the
    /// third form as "the third category" would file it as `other` and leave
    /// `many` — every count from 5 up — falling back to it. A locale absent
    /// from this table therefore fails the conversion instead of being
    /// guessed at.
    public static let pluralCategoriesByLocale: [String: [String]] = [
        "en": ["one", "other"],
        "sr": ["one", "few", "other"],
        "sr-Latn": ["one", "few", "other"],
    ]

    /// Qt counts with `%n`; the catalog's plural variants are consumed as
    /// `String(format:)` templates and count with `%lld`.
    static func rewriteCountPlaceholder(_ text: String) -> String {
        text.replacingOccurrences(of: "%n", with: "%lld")
    }

    /// The plural container for one `.ts` numerus message.
    static func pluralLocalization(id: String, locale: String,
                                   forms: [String]) throws -> Localization {
        guard let categories = pluralCategoriesByLocale[locale] else {
            throw ConversionError.unknownPluralLanguage(id: id, locale: locale)
        }
        guard forms.count == categories.count else {
            throw ConversionError.numerusFormCountMismatch(
                id: id, locale: locale, got: forms.count, expected: categories)
        }
        var plural: [String: Localization] = [:]
        for (category, form) in zip(categories, forms) {
            plural[category] = Localization(
                stringUnit: StringUnit(state: "translated",
                                       value: rewriteCountPlaceholder(form)))
        }
        return Localization(variations: PluralVariations(plural: plural))
    }

    /// Map a Qt locale code (`xx_YY`) to Apple's preferred form (`xx` /
    /// `xx-Yyyy`). Apple drops the region for unambiguous languages; the
    /// `sr_RS@latin` Qt suffix becomes Apple's `sr-Latn`.
    public static func appleLocale(forQt qt: String) -> String {
        if qt.contains("@latin") {
            return "sr-Latn"
        }
        let parts = qt.split(separator: "_")
        return String(parts.first ?? Substring(qt))
    }

    public static func convert(sources: [URL],
                               sourceLanguage: String) throws -> StringCatalog {
        var catalog = StringCatalog(sourceLanguage: sourceLanguage)
        for url in sources {
            let parser = TsParser()
            let messages = try parser.parse(url: url)
            let appleLocale = appleLocale(forQt: parser.language ?? "en_US")
            for msg in messages {
                if catalog.strings[msg.id] == nil {
                    catalog.strings[msg.id] = StringEntry(
                        comment: msg.id,
                        localizations: [:])
                }
                // An untranslated numerus message has no forms at all; it
                // degrades to its source, exactly as an untranslated plain
                // message does. A message with SOME forms but not the
                // locale's number of them is a mistranslation and stops the
                // conversion.
                if let forms = msg.numerusForms, !forms.isEmpty {
                    catalog.strings[msg.id]?.localizations[appleLocale] =
                        try pluralLocalization(id: msg.id, locale: appleLocale, forms: forms)
                    continue
                }
                var value = msg.translation ?? msg.source
                if msg.numerusForms != nil {
                    value = rewriteCountPlaceholder(value)
                }
                let unit = StringUnit(state: "translated", value: value)
                catalog.strings[msg.id]?.localizations[appleLocale] =
                    Localization(stringUnit: unit)
            }
        }
        return catalog
    }
}

// MARK: - .ts parser (XMLParser-based)

struct TsMessage {
    var id: String
    var source: String
    var translation: String?
    /// `nil` for a plain message; the `<numerusform>` bodies in file order
    /// for one marked `numerus="yes"` (possibly empty, if untranslated).
    var numerusForms: [String]?
}

final class TsParser: NSObject, XMLParserDelegate {
    private(set) var language: String?
    private var messages: [TsMessage] = []
    private var currentId: String?
    private var currentSource: String = ""
    private var currentTranslation: String = ""
    private var currentNumerus: Bool = false
    private var currentForm: String = ""
    private var currentForms: [String] = []
    private var currentElement: String = ""

    func parse(url: URL) throws -> [TsMessage] {
        guard let parser = XMLParser(contentsOf: url) else {
            throw NSError(domain: "ts2xcstrings", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot open .ts file at \(url.path)",
            ])
        }
        parser.delegate = self
        if !parser.parse() {
            throw parser.parserError ?? NSError(domain: "ts2xcstrings", code: 2)
        }
        return messages
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = element
        if element == "TS" {
            language = attributes["language"]
        } else if element == "message" {
            currentId = attributes["id"]
            currentSource = ""
            currentTranslation = ""
            currentNumerus = attributes["numerus"] == "yes"
            currentForms = []
        } else if element == "numerusform" {
            currentForm = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters text: String) {
        switch currentElement {
        case "source":
            currentSource += text
        case "translation":
            currentTranslation += text
        case "numerusform":
            currentForm += text
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if element == "numerusform" {
            currentForms.append(currentForm.trimmingCharacters(in: .whitespacesAndNewlines))
            currentForm = ""
        }
        if element == "message", let id = currentId {
            let trimmedTranslation = currentTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(TsMessage(
                id: id,
                source: currentSource.trimmingCharacters(in: .whitespacesAndNewlines),
                translation: trimmedTranslation.isEmpty ? nil : trimmedTranslation,
                numerusForms: currentNumerus ? currentForms : nil
            ))
            currentId = nil
            currentNumerus = false
            currentForms = []
        }
        currentElement = ""
    }
}

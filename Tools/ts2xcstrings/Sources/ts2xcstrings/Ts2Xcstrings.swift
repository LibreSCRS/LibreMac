// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

// MARK: - Apple String Catalog model (subset)

public struct StringUnit: Codable, Sendable {
    public var state: String  // "translated" | "needs_review" | "stale"
    public var value: String
}

public struct Localization: Codable, Sendable {
    public var stringUnit: StringUnit?
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

public enum Ts2Xcstrings {
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
                let unit = StringUnit(
                    state: "translated",
                    value: msg.translation ?? msg.source)
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
}

final class TsParser: NSObject, XMLParserDelegate {
    private(set) var language: String?
    private var messages: [TsMessage] = []
    private var currentId: String?
    private var currentSource: String = ""
    private var currentTranslation: String = ""
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
        }
    }

    func parser(_ parser: XMLParser, foundCharacters text: String) {
        switch currentElement {
        case "source":
            currentSource += text
        case "translation":
            currentTranslation += text
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if element == "message", let id = currentId {
            let trimmedTranslation = currentTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(TsMessage(
                id: id,
                source: currentSource.trimmingCharacters(in: .whitespacesAndNewlines),
                translation: trimmedTranslation.isEmpty ? nil : trimmedTranslation
            ))
            currentId = nil
        }
        currentElement = ""
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Pure, dependency-free reader-name → friendly-label logic, ported from
// LibreKDE's SmartCardHandler::readerDisplayLabels (C++/Qt). No SwiftUI/agent
// dependency, so it is unit-tested directly. Selection always uses the raw
// reader handle; only DISPLAY uses these labels. The "— contact/contactless"
// suffix formatters are injected so this file carries no localization state.

import Foundation
import LibreMacAgentClient

/// Parsed view of one raw PC/SC reader name.
struct ParsedReaderName: Equatable {
    var model: String  // short model label ("" -> caller falls back to raw)
    var contactless: Bool
    var serialTail: String  // last <=4 chars of the serial, to disambiguate twins
}

private func regexRemove(_ pattern: String, _ input: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return input
    }
    return re.stringByReplacingMatches(
        in: input, range: NSRange(input.startIndex..., in: input), withTemplate: "")
}

private func regexReplace(_ pattern: String, _ template: String, _ input: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return input
    }
    return re.stringByReplacingMatches(
        in: input, range: NSRange(input.startIndex..., in: input), withTemplate: template)
}

private func regexFirstCapture(_ pattern: String, _ input: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    guard let m = re.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
        m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: input)
    else { return nil }
    return String(input[r])
}

private func regexMatches(_ pattern: String, _ input: String) -> Bool {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return false
    }
    return re.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil
}

private func squashWhitespace(_ input: String) -> String {
    regexReplace("\\s+", " ", input).trimmingCharacters(in: .whitespaces)
}

/// Drop pcsc-lite generic words + interface markers from a candidate label.
private func cleanReaderToken(_ token: String) -> String {
    var t = token
    t = regexRemove("\\b(smart\\s*card|smartcard|reader|ccid|interface|usb|contactless|contact)\\b", t)
    t = regexReplace("([0-9])CL\\b", "$1", t)  // "5422CL" -> "5422"
    t = regexRemove("\\bCL\\b", t)
    return squashWhitespace(t)
}

func parseReaderName(_ raw: String) -> ParsedReaderName {
    var out = ParsedReaderName(model: "", contactless: false, serialTail: "")
    var s = raw.trimmingCharacters(in: .whitespaces)

    // Serial = the parenthesised group pcsc-lite appends ("(iSerial)").
    if let serial = regexFirstCapture("\\(([^)]+)\\)", s) {
        out.serialTail = String(serial.trimmingCharacters(in: .whitespaces).suffix(4))
    }

    // Strip trailing "(serial)" and the "<ifd> <slot>" number pair, either order
    // (run the number-pair strip twice to cover both orders).
    s = regexRemove("\\s*\\d+\\s+\\d+\\s*$", s)
    s = regexRemove("\\s*\\([^)]*\\)\\s*$", s)
    s = regexRemove("\\s*\\d+\\s+\\d+\\s*$", s)
    s = s.trimmingCharacters(in: .whitespaces)

    // Split "PREFIX [BRACKET]" — the bracket usually holds the cleaner model.
    var prefix = s
    var bracket = ""
    if let b = regexFirstCapture("\\[([^\\]]*)\\]", s) {
        bracket = b.trimmingCharacters(in: .whitespaces)
        if let openBracket = s.firstIndex(of: "[") {
            prefix = String(s[..<openBracket]).trimmingCharacters(in: .whitespaces)
        }
    }

    out.contactless = regexMatches("contactless|\\bpicc\\b|\\bnfc\\b|[0-9]\\s*CL\\b|\\bCL\\b", s)

    let cleanedBracket = cleanReaderToken(bracket)
    let cleanedPrefix = cleanReaderToken(prefix)
    // Prefer the bracket when it yields a model-like token (a digit or a space);
    // otherwise the prefix; never empty (caller falls back to the raw name).
    let bracketModelLike =
        !cleanedBracket.isEmpty
        && (regexMatches("[0-9]", cleanedBracket) || cleanedBracket.contains(" "))
    out.model =
        bracketModelLike ? cleanedBracket : (cleanedPrefix.isEmpty ? cleanedBracket : cleanedPrefix)
    return out
}

/// Full-roster label map (handle -> friendly label). Computed over ALL readers
/// so a card-less contactless sibling still drives the contact/contactless
/// disambiguation.
func readerDisplayLabels(
    _ readers: [ReaderState],
    contact: (_ model: String) -> String,
    contactless: (_ model: String) -> String
) -> [String: String] {
    var parsed: [ParsedReaderName] = []
    var contactlessPerModel: [String: Int] = [:]
    for reader in readers {
        var p = parseReaderName(reader.name)
        if p.model.isEmpty { p.model = reader.name.trimmingCharacters(in: .whitespaces) }
        if p.contactless { contactlessPerModel[p.model, default: 0] += 1 }
        parsed.append(p)
    }

    var labels: [String] = []
    for p in parsed {
        if p.contactless {
            labels.append(contactless(p.model))
        } else if (contactlessPerModel[p.model] ?? 0) > 0 {
            labels.append(contact(p.model))  // a contactless sibling exists
        } else {
            labels.append(p.model)
        }
    }

    // Uniqueness: on a residual collision append a serial tail, else a 1-based index.
    var seen: [String: Int] = [:]
    for l in labels { seen[l, default: 0] += 1 }
    for i in labels.indices where (seen[labels[i]] ?? 0) > 1 {
        let tail = parsed[i].serialTail
        var disambiguated = tail.isEmpty ? "\(labels[i]) (\(i + 1))" : "\(labels[i]) (\(tail))"
        if (seen[disambiguated] ?? 0) > 0 { disambiguated = "\(labels[i]) (\(i + 1))" }
        seen[disambiguated, default: 0] += 1
        labels[i] = disambiguated
    }

    var map: [String: String] = [:]
    for (i, reader) in readers.enumerated() { map[reader.handle] = labels[i] }
    return map
}

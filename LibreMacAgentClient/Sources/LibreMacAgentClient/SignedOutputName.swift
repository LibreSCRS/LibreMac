// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Where a signature of a document is written: the one naming rule every client
// of the agent uses, so the same document signed from any of them lands under
// the same name. Mirrors `signedOutputPath()` of the Qt client library, which
// this Swift client cannot link; `SignedOutputNameTests` holds both to the same
// cases.
//
// | format | packaging | output              |
// |--------|-----------|---------------------|
// | PAdES  | any       | `<stem>-signed.pdf` |
// | XAdES  | detached  | `<name>.xsig`       |
// | XAdES  | enveloped | `<stem>-signed.xml` |
// | CAdES  | detached  | `<name>.p7s`        |
// | CAdES  | enveloped | `<name>.p7m`        |
// | JAdES  | any       | `<name>.jose`       |
// | ASiCe  | any       | `<stem>.asice`      |
//
// `<name>` is the input's file name, `<stem>` that name without its last
// extension. A taken name gets the first free numbered sibling, the number
// before the last extension (`report-signed (2).pdf`, then `(3)`, ...).

import Foundation

public enum SignedOutputName {

    /// The most numbered siblings looked at before giving up; bounds the search
    /// in a folder that holds that many.
    static let maxSiblings = 10_000

    /// The output file name for an input named `inputName`, or `nil` for a
    /// format or packaging that is only a request-side deferral (`.auto`) or an
    /// empty name — those never name a file.
    public static func name(
        forInputName inputName: String, format: SignatureFormat, packaging: Packaging
    ) -> String? {
        guard !inputName.isEmpty else { return nil }
        let stem = split(inputName).stem
        switch format {
        case .pades:
            return stem + "-signed.pdf"
        case .xades:
            switch packaging {
            case .detached: return inputName + ".xsig"
            case .enveloped: return stem + "-signed.xml"
            case .auto: return nil
            }
        case .cades:
            switch packaging {
            case .detached: return inputName + ".p7s"
            case .enveloped: return inputName + ".p7m"
            case .auto: return nil
            }
        case .jades:
            return inputName + ".jose"
        case .asice:
            return stem + ".asice"
        case .auto:
            return nil
        }
    }

    /// The path a signature of `input` is written to, in `folder`: never one
    /// `isTaken` reports as existing. `nil` when no name is free, so the caller
    /// reports a failure instead of replacing anything. A snapshot — the file
    /// has to be created exclusively.
    public static func url(
        forInput input: URL, format: SignatureFormat, packaging: Packaging,
        in folder: URL, isTaken: (URL) -> Bool
    ) -> URL? {
        guard let name = name(forInputName: input.lastPathComponent, format: format, packaging: packaging)
        else { return nil }
        let first = folder.appendingPathComponent(name)
        if !isTaken(first) { return first }
        let (base, suffix) = split(name)
        for counter in 2...maxSiblings {
            let candidate = folder.appendingPathComponent("\(base) (\(counter)).\(suffix)")
            if !isTaken(candidate) { return candidate }
        }
        return nil
    }

    /// The part of `name` before its last dot and the part after it; the whole
    /// name and an empty suffix when it has no dot. The same cut as Qt's
    /// `completeBaseName()` / `suffix()`, so a leading dot starts the suffix.
    private static func split(_ name: String) -> (stem: String, suffix: String) {
        guard let dot = name.lastIndex(of: ".") else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}

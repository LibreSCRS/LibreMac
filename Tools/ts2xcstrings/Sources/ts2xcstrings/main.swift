// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

// CLI entry point. Used at Xcode build-phase time:
//   ts2xcstrings --output Localizable.xcstrings <ts1> [<ts2> ...]

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data(
        "Usage: ts2xcstrings --output <catalog.xcstrings> <ts1> [<ts2> ...]\n".utf8))
    exit(2)
}
guard let outIdx = args.firstIndex(of: "--output"), outIdx + 1 < args.count else {
    FileHandle.standardError.write(Data("Missing --output flag\n".utf8))
    exit(2)
}
let outputUrl = URL(fileURLWithPath: args[outIdx + 1])
let inputUrls = args[(outIdx + 2)...].map { URL(fileURLWithPath: $0) }

do {
    var catalog = try Ts2Xcstrings.convert(sources: Array(inputUrls), sourceLanguage: "en")

    // Merge: preserve manually-maintained entries already present in the
    // output catalog (e.g. LibreMac-side `error.*` keys that the bridge
    // throws — these have no `.ts` source and would otherwise be wiped on
    // every regeneration). Imported `.ts` keys take precedence; manual
    // keys not present in the imports are carried forward verbatim.
    if FileManager.default.fileExists(atPath: outputUrl.path) {
        if let existingData = try? Data(contentsOf: outputUrl),
           let existing = try? JSONDecoder().decode(StringCatalog.self, from: existingData) {
            for (key, entry) in existing.strings where catalog.strings[key] == nil {
                catalog.strings[key] = entry
            }
        }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(catalog)
    try data.write(to: outputUrl)
} catch {
    FileHandle.standardError.write(
        Data("ts2xcstrings failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

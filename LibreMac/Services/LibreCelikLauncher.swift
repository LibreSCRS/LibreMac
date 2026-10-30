// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Opens the card in LibreCelik, the desktop reader of the same release. Like
// LibreCelik's own lookup of this app, only a copy in an Applications folder
// counts: one on a mounted disk image or in Downloads runs translocated and
// is not the installed product.

import AppKit
import os

enum LibreCelikLauncher {
    static let bundleIdentifier = "rs.librescrs.librecelik"

    /// Every copy Launch Services knows by bundle identifier.
    typealias Lookup = () -> [URL]

    static func installedURL(
        lookup: Lookup = { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier) },
        home: String = NSHomeDirectory()
    ) -> URL? {
        lookup()
            .map { $0.resolvingSymlinksInPath() }
            .first { inApplications($0.path, home: home) }
    }

    /// The system folder (also reachable through the data volume's firmlink)
    /// and the per-user one.
    static func inApplications(_ path: String, home: String) -> Bool {
        path.hasPrefix("/Applications/")
            || path.hasPrefix("/System/Volumes/Data/Applications/")
            || path.hasPrefix(home + "/Applications/")
    }

    /// Any card in the reader, whatever this menu itself can do with it.
    static func offers(for presence: Presence) -> Bool {
        if case .card(let state) = presence { return state != .noCard }
        return false
    }

    /// Activates LibreCelik, launching it when it is not running.
    /// LibreCelik takes no card argument: it shows the card in the reader.
    @MainActor
    static func open(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Logger.app.error("LibreCelik did not open: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

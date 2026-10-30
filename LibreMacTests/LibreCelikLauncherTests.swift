// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import Testing

@testable import LibreMac

@Suite("Open in LibreCelik")
struct LibreCelikLauncherTests {
    private let home = "/Users/u"

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    @Test("only a copy in an Applications folder is the installed one")
    func applicationsOnly() {
        #expect(LibreCelikLauncher.inApplications("/Applications/LibreCelik.app", home: home))
        #expect(
            LibreCelikLauncher.inApplications("/System/Volumes/Data/Applications/LibreCelik.app", home: home))
        #expect(LibreCelikLauncher.inApplications("/Users/u/Applications/LibreCelik.app", home: home))
        #expect(!LibreCelikLauncher.inApplications("/Volumes/LibreSCRS/LibreCelik.app", home: home))
        #expect(!LibreCelikLauncher.inApplications("/Users/u/Downloads/LibreCelik.app", home: home))
        #expect(!LibreCelikLauncher.inApplications("/Users/other/Applications/LibreCelik.app", home: home))
        #expect(!LibreCelikLauncher.inApplications("/ApplicationsOld/LibreCelik.app", home: home))
    }

    @Test("the installed copy is chosen over one Launch Services lists first")
    func picksInstalledCopy() {
        let found = LibreCelikLauncher.installedURL(
            lookup: { [url("/Volumes/LibreSCRS/LibreCelik.app"), url("/Applications/LibreCelik.app")] },
            home: home)
        #expect(found?.path == "/Applications/LibreCelik.app")
    }

    @Test("no installed copy, no menu item")
    func noneInstalled() {
        #expect(LibreCelikLauncher.installedURL(lookup: { [] }, home: home) == nil)
        #expect(
            LibreCelikLauncher.installedURL(
                lookup: { [url("/Users/u/Downloads/LibreCelik.app")] }, home: home) == nil)
    }

    @Test("offered for any card in the reader, and only then")
    func offeredWithACard() {
        for state in [CardUiState.none, .preAuthRequired, .identityOnly, .pkiOnly, .hybrid, .error] {
            #expect(LibreCelikLauncher.offers(for: .card(state)))
        }
        #expect(!LibreCelikLauncher.offers(for: .card(.noCard)))
        #expect(!LibreCelikLauncher.offers(for: .readerEmpty))
        #expect(!LibreCelikLauncher.offers(for: .noReader))
        #expect(!LibreCelikLauncher.offers(for: .agentUnavailable))
    }
}

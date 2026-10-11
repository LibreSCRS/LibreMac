// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import Testing
@testable import LibreMac

@Suite("App translocation")
struct AppTranslocationTests {
    private let moved = URL(fileURLWithPath:
        "/private/var/folders/xy/abc/T/AppTranslocation/1F2E3D4C/d/LibreMac.app")
    private let installed = URL(fileURLWithPath: "/Applications/LibreMac.app")

    @Test("the system answer wins when there is one")
    func systemAnswerWins() {
        #expect(AppTranslocation.isTranslocated(installed, probe: { _ in true }))
        #expect(!AppTranslocation.isTranslocated(moved, probe: { _ in false }))
    }

    @Test("without the system call, the AppTranslocation path component decides")
    func pathFallback() {
        #expect(AppTranslocation.isTranslocated(moved, probe: { _ in nil }))
        #expect(!AppTranslocation.isTranslocated(installed, probe: { _ in nil }))
        #expect(!AppTranslocation.isTranslocated(
            URL(fileURLWithPath: "/Users/u/AppTranslocationNotes/LibreMac.app"), probe: { _ in nil }))
    }

    @Test("the test host, built in place, is not translocated")
    func testHostInPlace() {
        #expect(!AppTranslocation.isTranslocated(Bundle.main.bundleURL))
    }
}

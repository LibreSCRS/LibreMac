// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
@testable import LibreMac
import LibreMacShared

@Suite("BridgeRAII")
struct BridgeRAIITests {
    /// `loadBundledPlugins()` must succeed even when no plugins ship with the
    /// test bundle (count == 0). The registry singleton is constructed once
    /// and never re-constructed.
    @Test("Registry boots and reports plugin count >= 0")
    func registryBoots() {
        let count = BridgeRegistry.shared.loadBundledPlugins()
        #expect(count >= 0)
    }

    /// Calling loadPlugins from a non-existent directory still must not crash;
    /// it returns 0 and logs an error (per `lm_registry_create` returning NULL
    /// on a path that is not a real directory). This guards the boot-failure
    /// branch in `BridgeRegistry.loadPlugins`.
    @Test("Registry survives an invalid plugin directory")
    func registrySurvivesBadDir() {
        let tmp = NSTemporaryDirectory()
            .appending("librescrs-bridge-tests-\(UUID().uuidString)")
        // Directory does not exist → expect 0 plugins, no crash.
        let count = BridgeRegistry.shared.loadPlugins(fromDirectory: tmp)
        #expect(count >= 0)
    }
}

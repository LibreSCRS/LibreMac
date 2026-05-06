// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import LibreMacShared
import SwiftUI
import os

@main
struct LibreMacApp: App {
    /// App-scope BridgeRegistry — the LibreMac composition root. Constructor-
    /// injected into every consumer; never accessed via a global. A future
    /// CTK appex (P4) will construct its own `BridgeRegistry` rooted at the
    /// appex bundle's PlugIns directory.
    private let registry: BridgeRegistry
    @State private var monitor: CardMonitor
    @State private var signing: SigningCoordinator

    // The coordinator is created once at app launch and lives for the
    // app's lifetime. It queries `cardMonitor.activeSession` on demand;
    // a brief reader drop on USB jitter no longer destroys in-flight
    // signing UX state. Per Apple's @Observable lifetime guidance
    // (WWDC22 "Discover Observation"): view models should outlive
    // transient state; their lifetime matches the scene's.
    init() {
        Logger.app.info("LibreMac launched")
        let r = BridgeRegistry()
        r.loadBundledPlugins()
        self.registry = r
        let m = CardMonitor(registry: r)
        self._monitor = State(initialValue: m)
        self._signing = State(initialValue: SigningCoordinator(cardMonitor: m))
    }

    var body: some Scene {
        MenuBarExtra("LibreMac", systemImage: menuBarIcon) {
            CardStatusView()
                .environment(monitor)
                .padding(.horizontal, 12).padding(.top, 8)

            if monitor.activeSession != nil {
                Divider()
                SignDemoView(coordinator: signing)
                    .environment(monitor)
            }

            Divider()
            SettingsLink { Text("Preferences…") }
            Button("Quit LibreMac") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        Settings { PreferencesView() }
    }

    private var menuBarIcon: String {
        switch monitor.status {
        case .noReader, .readerConnected: return "creditcard"
        case .cardPresent, .readingCertificates: return "creditcard.fill"
        case .ready: return "checkmark.seal.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

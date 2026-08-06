// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The settings window. Two backing stores, never blurred: client-local rows
// live in user defaults, agent-backed rows go over the socket and are owned
// by the agent. Panes for the agent-backed rows arrive with their tabs.

import AppKit
import LibreMacAgentClient
import SwiftUI

// The model is main-actor isolated, so the view holding it is too.
@MainActor
struct PreferencesView: View {
    @Environment(AppLocalization.self) private var localization

    /// Owned by the app delegate, not created here: this window is opened
    /// and closed repeatedly, and the model follows a stream that does not
    /// survive its consumer being cancelled.
    let model: PreferencesModel

    /// The activation policy to put back when this window closes; nil while it
    /// is not open.
    @State private var previousPolicy: NSApplication.ActivationPolicy?

    /// The keys this window actually draws a control for.
    static let settableKeysWithControls: Set<SettableConfigKey> =
        [.defaultLevel, .defaultReason, .defaultLocation]

    /// Keys deliberately not drawn yet: the trust-tier pair ships with the
    /// trust pane, once the agent-side gate exists. Empty this when they land.
    static let deferredSettableKeys: Set<SettableConfigKey> = [.tsaUrls, .tslSources]

    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Text(localization.loc("lc-settings-tab-general", "General")) }
            SigningPane(model: model)
                .tabItem { Text(localization.loc("lc-settings-tab-signing", "Signing")) }
            AdvancedPane(model: model)
                .tabItem {
                    Text(localization.loc("libremac_settings_tab_advanced", "Advanced"))
                }
        }
        .frame(width: 560, height: 420)
        // Refresh on open. Following the agent's change signal is the app
        // delegate's job, not this window's: the stream would not survive
        // this task being cancelled when the window closes.
        .task { await model.load() }
        // SwiftUI opens this window for us, and an accessory app is never the
        // active application — so without this it appears behind whatever was
        // frontmost, which is exactly where users found it.
        .onAppear { previousPolicy = AppActivation.begin() }
        .onDisappear {
            if let previousPolicy {
                AppActivation.end(restoring: previousPolicy)
            }
            previousPolicy = nil
        }
    }
}

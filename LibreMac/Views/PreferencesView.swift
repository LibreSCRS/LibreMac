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
        [.defaultLevel, .defaultReason, .defaultLocation, .tsaUrls, .tslSources]

    /// Keys deliberately not drawn, and the guard keeps it honest: a key listed
    /// here as well as drawn fails the build, so a deferral cannot outlive the
    /// deferring.
    ///
    /// `cscaSources` is deferred rather than drawn because a control with no
    /// effect is the mistake this project has already reverted once elsewhere.
    /// The agent gates country-signing sources behind the trust tier, and this
    /// host has no import path to pair a source list with; a field that accepts
    /// text and changes nothing a person can observe is worse than its absence.
    /// The key still round-trips through the model, so nothing is LOST on a
    /// refused write -- which is the whole reason this set exists.
    static let deferredSettableKeys: Set<SettableConfigKey> = [.cscaSources]

    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Text(localization.loc("lc-settings-tab-general", "General")) }
            SigningPane(model: model)
                .tabItem { Text(localization.loc("lc-settings-tab-signing", "Signing")) }
            TrustPane(model: model)
                .tabItem { Text(localization.loc("lc-settings-tab-trust", "Trust")) }
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

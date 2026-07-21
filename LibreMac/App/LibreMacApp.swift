// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import AppKit
import LibreMacAgentClient
import LibreMacShared
import SwiftUI
import os

/// Composition root. Owns the single `AgentClient` and the view models rooted
/// on it, registers the agent + prompter LaunchAgents, and — crucially — owns
/// the client's LIFETIME: `AgentClient.deinit` does NOT close its connection
/// (the supervisor task holds the socket), so the client is explicitly
/// `stop()`ped on termination. The host holds no card session and touches no
/// smart-card subsystem — it is a pure agent client.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let client: AgentClient
    let monitor: CardMonitor
    let signing: SigningCoordinator
    /// The app's ONE credentials view model, fed through a
    /// `CredentialsClientAdapter` rather than the shared client directly:
    /// the client's registry/quiescence `AsyncStream`s are unicast and
    /// `monitor` consumes them, so the credentials events come from
    /// `monitor`'s forwarding taps instead.
    let credentials: CredentialsViewModel
    let registrar: AgentRegistrar
    /// Publishes the signing card's Keychain identities to `ctkd`. Driven by
    /// `monitor` on card presence/removal (see `CardMonitor`'s "Token
    /// identity publishing" section); the app delegate only re-registers it
    /// once on launch, below.
    let tokenIdentityRegistrar: TokenIdentityRegistrar

    override init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let client = AgentClient(clientVersion: "LibreMac/\(version)")
        self.client = client
        let tokenIdentityRegistrar = TokenIdentityRegistrar(
            store: DriverConfigStore(classID: "org.librescrs.LibreMacToken"))
        self.tokenIdentityRegistrar = tokenIdentityRegistrar
        let monitor = CardMonitor(client: client, tokenRegistrar: tokenIdentityRegistrar)
        self.monitor = monitor
        self.signing = SigningCoordinator(client: client)
        self.credentials = CredentialsViewModel(
            client: CredentialsClientAdapter(client: client, monitor: monitor))
        self.registrar = AgentRegistrar.system()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.app.info("LibreMac launched")
        // Clear any driver configuration left over from a prior run before
        // the first card-presence snapshot arrives — `TKTokenDriverConfiguration`
        // goes stale across a ctkd restart with no refresh API (FB22701547),
        // so the host must recycle it on every launch. No card is known yet
        // at this point, so this is a pure clear; `monitor` republishes once
        // a signing card's certificates are read.
        tokenIdentityRegistrar.reregisterOnLaunch(currentCerts: [])
        // Registration first (materializes the App-Group container off-main),
        // then bring the client up; both are independent async flows.
        Task { await registrar.activate() }
        Task { await client.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Close the socket and cancel the supervisor deterministically —
        // deinit alone would leave the connection open until process exit.
        Task { await client.stop() }
    }
}

@main
struct LibreMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("LibreMac", systemImage: menuBarIcon) {
            CardStatusView()
                .environment(appDelegate.monitor)
                .padding(.horizontal, 12).padding(.top, 8)

            if appDelegate.registrar.state == .requiresApproval {
                Divider()
                Button(loc("libremac_registrar_approve", "Approve the signing agent in Login Items…")) {
                    appDelegate.registrar.openLoginItemsSettings()
                }
            }

            if appDelegate.monitor.canSign {
                Divider()
                SignDemoView(coordinator: appDelegate.signing)
                    .environment(appDelegate.monitor)
            }

            CredentialsMenuItem()
                .environment(appDelegate.monitor)

            Divider()
            SettingsLink { Text(loc("libremac_menu_preferences", "Preferences…")) }
            Button(loc("libremac_menu_quit", "Quit LibreMac")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        Window(loc("libremac_credentials_title", "Card Credentials"), id: "credentials") {
            CredentialsView(viewModel: appDelegate.credentials)
                .environment(appDelegate.monitor)
        }
        .defaultSize(width: 520, height: 360)

        Settings { PreferencesView() }
    }

    private var menuBarIcon: String {
        switch appDelegate.monitor.presence {
        case .agentUnavailable:
            return "bolt.horizontal.circle"
        case .noReader, .readerEmpty:
            return "creditcard"
        case .card(let state):
            switch state {
            case .pkiOnly, .hybrid: return "checkmark.seal.fill"
            case .identityOnly: return "person.text.rectangle"
            case .preAuthRequired: return "lock.fill"
            case .error, .none, .noCard: return "exclamationmark.triangle.fill"
            }
        case .quiesced:
            return "moon.zzz.fill"
        }
    }

    private func loc(_ key: String, _ fallback: String) -> String {
        LocalizedText(key: key, defaultText: fallback).resolve()
    }
}

/// The gated "Card Credentials…" menu item. A separate view (not inline in
/// the `App` body) because `@Environment(\.openWindow)` resolves in a view
/// hierarchy. Shown only when the connected agent advertises the
/// `"credentials"` feature AND a present card carries the PinManagement
/// capability — read from `CardMonitor.cards` directly, since the coarse
/// `Presence` grouping deliberately ignores that bit.
private struct CredentialsMenuItem: View {
    @Environment(CardMonitor.self) var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if monitor.agentFeatures.contains("credentials")
            && monitor.cards.contains(where: { $0.caps.contains(.pinManagement) }) {
            Divider()
            Button(loc("libremac_credentials_menu", "Card Credentials…")) {
                // LSUIElement app: without an explicit activation the new
                // window opens BEHIND the frontmost app. Activate first.
                NSApp.activate()
                openWindow(id: "credentials")
            }
        }
    }

    private func loc(_ key: String, _ fallback: String) -> String {
        LocalizedText(key: key, defaultText: fallback).resolve()
    }
}

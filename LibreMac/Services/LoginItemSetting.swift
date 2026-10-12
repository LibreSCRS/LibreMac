// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// "Open LibreMac at login": the host's own login item (`SMAppService.mainApp`),
// behind the same `LaunchAgentRegistering` seam as the agent and the prompter.
// launchd starts those two at login on its own; without this the menu-bar
// icon stays away until the user opens the app by hand.
//
// On by default: the first launch from an Applications folder registers it
// once. After that the system's status is the only state -- the user may
// change it here or in System Settings › Login Items, and a launch never turns
// it back on. A copy anywhere else (a build product, a test host, a
// translocated copy) never registers itself: login would open a path that
// moves or vanishes.

import Foundation
import LibreMacShared
import Observation
import os

@MainActor
@Observable
final class LoginItemSetting {

    /// Registered, whether or not macOS still waits for approval.
    private(set) var isOn = false
    /// Registered, but macOS will not open it until the user approves it in
    /// System Settings › Login Items.
    private(set) var needsApproval = false
    /// The last change the user asked for did not take; the pane says so.
    private(set) var changeFailed = false

    @ObservationIgnored private let item: LaunchAgentRegistering
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let openSettings: @Sendable () -> Void
    @ObservationIgnored private let isInstalled: @Sendable () -> Bool

    /// Set once the first-launch default has been applied, so a user who
    /// turned the setting off is never overruled.
    static let defaultAppliedKey = "org.librescrs.LibreMac.openAtLoginDefaultApplied"

    init(
        item: LaunchAgentRegistering,
        defaults: UserDefaults,
        isInstalled: @escaping @Sendable () -> Bool,
        openSettings: @escaping @Sendable () -> Void
    ) {
        self.item = item
        self.defaults = defaults
        self.isInstalled = isInstalled
        self.openSettings = openSettings
    }

    /// True for a bundle directly inside /Applications or ~/Applications.
    nonisolated static func isInApplicationsFolder(_ bundleURL: URL) -> Bool {
        let parent = bundleURL.standardizedFileURL.deletingLastPathComponent().path
        // The passwd home: under the App Sandbox the home directory APIs
        // answer with this app's container.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let userApplications = URL(fileURLWithPath: home).appendingPathComponent("Applications").standardizedFileURL.path
        return parent == "/Applications" || parent == userApplications
    }

    /// Reads the system's status; call when the setting is shown. A refusal
    /// noted earlier is history once the status is read again: the user may
    /// have made the change in System Settings since.
    func refresh() {
        changeFailed = false
        let status = item.status()
        isOn = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    /// The first-launch default. Recorded only once the item is on, so a
    /// registration that failed is tried again on the next launch.
    func applyDefaultOnce() {
        defer { refresh() }
        guard isInstalled(), !defaults.bool(forKey: Self.defaultAppliedKey) else { return }
        switch item.status() {
        case .notRegistered, .notFound:
            do {
                try item.register()
            } catch {
                Logger.app.error(
                    "could not register the login item: \(error.localizedDescription, privacy: .public)")
                return
            }
        case .enabled, .requiresApproval:
            break
        }
        defaults.set(true, forKey: Self.defaultAppliedKey)
    }

    func setOn(_ on: Bool) {
        do {
            if on {
                try item.register()
            } else {
                try item.unregister()
            }
            refresh()
        } catch {
            Logger.app.error(
                "could not change the login item: \(error.localizedDescription, privacy: .public)")
            refresh()
            // After refresh(), which clears it. Also a change the toggle sees:
            // refresh() alone may write back the value isOn already held,
            // which redraws nothing.
            changeFailed = true
        }
    }

    func openLoginItemsSettings() {
        openSettings()
    }
}

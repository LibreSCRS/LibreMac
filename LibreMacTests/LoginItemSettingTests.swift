// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The "open at login" setting through the same `LaunchAgentRegistering` seam
// the agent registrar uses (`SMAppService.mainApp` has the same shape and is
// no more mockable than the agents).

import Foundation
import Testing

@testable import LibreMac

@MainActor
@Suite("Open at login")
final class LoginItemSettingTests {

    private var suites: [String] = []

    deinit {
        // Leave no preference file behind in the test host's container.
        for name in suites {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "LoginItemSettingTests.\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("the first launch turns it on")
    func firstLaunchTurnsItOn() {
        let item = FakeLaunchAgent(label: "app", status: .notRegistered)
        let setting = LoginItemSetting(item: item, defaults: makeDefaults(), isInstalled: { true }, openSettings: {})
        setting.applyDefaultOnce()
        #expect(item.registerCount == 1)
        #expect(setting.isOn)
    }

    @Test("turned off by the user, it stays off on the next launch")
    func userChoiceSurvivesTheNextLaunch() {
        let defaults = makeDefaults()
        let item = FakeLaunchAgent(label: "app", status: .notRegistered)
        LoginItemSetting(item: item, defaults: defaults, isInstalled: { true }, openSettings: {}).applyDefaultOnce()

        let setting = LoginItemSetting(item: item, defaults: defaults, isInstalled: { true }, openSettings: {})
        setting.setOn(false)
        #expect(!setting.isOn)

        LoginItemSetting(item: item, defaults: defaults, isInstalled: { true }, openSettings: {}).applyDefaultOnce()
        #expect(item.registerCount == 1)
        #expect(item.status() == .notRegistered)
    }

    @Test("a failed first registration is tried again on the next launch")
    func failedDefaultIsRetried() {
        let defaults = makeDefaults()
        let failing = FakeLaunchAgent(label: "app", status: .notRegistered, registerError: RegistrarTestError())
        let first = LoginItemSetting(item: failing, defaults: defaults, isInstalled: { true }, openSettings: {})
        first.applyDefaultOnce()
        #expect(!first.isOn)

        let item = FakeLaunchAgent(label: "app", status: .notRegistered)
        LoginItemSetting(item: item, defaults: defaults, isInstalled: { true }, openSettings: {}).applyDefaultOnce()
        #expect(item.registerCount == 1)
    }

    @Test("waiting for approval reads as on, and says so")
    func approvalPendingIsOnAndFlagged() {
        let item = FakeLaunchAgent(label: "app", status: .notRegistered, statusAfterRegister: .requiresApproval)
        let setting = LoginItemSetting(item: item, defaults: makeDefaults(), isInstalled: { true }, openSettings: {})
        setting.applyDefaultOnce()
        #expect(setting.isOn)
        #expect(setting.needsApproval)
    }

    @Test("a copy outside an Applications folder never registers itself")
    func uninstalledCopyDoesNotRegister() {
        let defaults = makeDefaults()
        let item = FakeLaunchAgent(label: "app", status: .notRegistered)
        LoginItemSetting(item: item, defaults: defaults, isInstalled: { false }, openSettings: {}).applyDefaultOnce()
        #expect(item.registerCount == 0)
        // ... and the default is still owed to the installed copy.
        LoginItemSetting(item: item, defaults: defaults, isInstalled: { true }, openSettings: {}).applyDefaultOnce()
        #expect(item.registerCount == 1)
    }

    @Test("only a bundle directly in an Applications folder counts as installed")
    func applicationsFolderRule() {
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        #expect(LoginItemSetting.isInApplicationsFolder(URL(fileURLWithPath: "/Applications/LibreMac.app")))
        #expect(LoginItemSetting.isInApplicationsFolder(home.appendingPathComponent("Applications/LibreMac.app")))
        #expect(!LoginItemSetting.isInApplicationsFolder(URL(fileURLWithPath: "/Applications/Utilities/x/LibreMac.app")))
        #expect(!LoginItemSetting.isInApplicationsFolder(
            URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/LibreMac.app")))
        #expect(!LoginItemSetting.isInApplicationsFolder(
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData/x/Build/Products/Debug/LibreMac.app")))
    }

    @Test("already on at first launch, a later \"off\" is still respected")
    func alreadyOnRecordsTheDefault() {
        let defaults = makeDefaults()
        let item = FakeLaunchAgent(label: "app", status: .enabled)
        LoginItemSetting(item: item, defaults: defaults, isInstalled: { true }, openSettings: {}).applyDefaultOnce()
        #expect(item.registerCount == 0)
        LoginItemSetting(item: item, defaults: defaults, isInstalled: { true }, openSettings: {}).setOn(false)
        LoginItemSetting(item: item, defaults: defaults, isInstalled: { true }, openSettings: {}).applyDefaultOnce()
        #expect(item.status() == .notRegistered)
    }

    @Test("a change macOS refuses leaves the toggle off and says so")
    func refusedChangeIsReported() {
        let item = FakeLaunchAgent(label: "app", status: .notRegistered, registerError: RegistrarTestError())
        let setting = LoginItemSetting(item: item, defaults: makeDefaults(), isInstalled: { true }, openSettings: {})
        setting.setOn(true)
        #expect(!setting.isOn)
        #expect(setting.changeFailed)
    }

    @Test("the refusal note goes once the status is read again")
    func refusalNoteClearsOnRefresh() {
        let item = FakeLaunchAgent(label: "app", status: .notRegistered, registerError: RegistrarTestError())
        let setting = LoginItemSetting(item: item, defaults: makeDefaults(), isInstalled: { true }, openSettings: {})
        setting.setOn(true)
        #expect(setting.changeFailed)
        setting.refresh()  // the pane reappears, after the user tried System Settings
        #expect(!setting.changeFailed)
    }

    @Test("a change made in System Settings shows after refresh")
    func refreshFollowsTheSystem() {
        let item = FakeLaunchAgent(label: "app", status: .enabled)
        let setting = LoginItemSetting(item: item, defaults: makeDefaults(), isInstalled: { true }, openSettings: {})
        setting.refresh()
        #expect(setting.isOn)
        try? item.unregister()  // the user removed it in Login Items
        setting.refresh()
        #expect(!setting.isOn)
    }
}

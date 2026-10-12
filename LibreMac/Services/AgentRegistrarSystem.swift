// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The production wiring for `AgentRegistrar`: the concrete `SMAppService`
// LaunchAgent adapter and the composition-root factory. Isolated from
// `AgentRegistrar.swift` so the state-machine file imports no
// `ServiceManagement` and stays trivially unit-testable.

import Foundation
import LibreMacAgentClient
import LibreMacShared
import Security
import ServiceManagement

/// `LaunchAgentRegistering` backed by a real `SMAppService.agent(plistName:)`.
///
/// Stores only the plist name (a `Sendable` `String`) and materializes a fresh
/// `SMAppService` handle per call — `SMAppService` itself is a non-`Sendable`
/// reference type, and a handle is a cheap by-name lookup, so nothing
/// non-`Sendable` is ever stored or escapes a single call.
struct SMAppServiceAgent: LaunchAgentRegistering {
    let label: String
    private let plistName: String

    init(plistName: String) {
        self.label = plistName
        self.plistName = plistName
    }

    private func service() -> SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    func status() -> LaunchAgentStatus {
        switch service().status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws {
        try service().register()
    }

    func unregister() throws {
        try service().unregister()
    }
}

/// The host itself as a login item (`SMAppService.mainApp`), behind the same
/// seam: same status, register and unregister, and just as unmockable.
struct SMAppServiceMainApp: LaunchAgentRegistering {
    let label = "LibreMac.app"

    func status() -> LaunchAgentStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

extension LoginItemSetting {

    /// The production setting: the host's own login item, its first-launch
    /// record in the host's defaults, and the Login Items opener.
    static func system() -> LoginItemSetting {
        LoginItemSetting(
            item: SMAppServiceMainApp(), defaults: .standard,
            isInstalled: { LoginItemSetting.isInApplicationsFolder(Bundle.main.bundleURL) },
            openSettings: { SMAppService.openSystemSettingsLoginItems() })
    }
}

extension AgentRegistrar {

    /// Builds the production registrar: the agent + prompter LaunchAgents, the
    /// off-main App-Group container materializer, a recycle trigger keyed on
    /// the signed bundle itself (see `bundleStamp`), and the Login Items
    /// opener.
    public static func system(
        appGroupId: String = AgentSocketPath.appGroupIdentifier,
        bundleURL: URL = Bundle.main.bundleURL,
        bundleVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    ) -> AgentRegistrar {
        // Both closures share one stamp, computed once: what is compared is
        // exactly what gets recorded.
        let trigger = recycleTrigger(
            suiteName: appGroupId,
            stamp: bundleStamp(bundleVersion: bundleVersion, bundleURL: bundleURL))
        return AgentRegistrar(
            services: [
                SMAppServiceAgent(plistName: AppGroupConstants.AgentService.launchdPlistName),
                SMAppServiceAgent(plistName: AppGroupConstants.AgentService.prompterPlistName),
            ],
            materializeContainer: {
                // The first container touch TCC-prompts and BLOCKS — force
                // it off the main actor so the UI never wedges behind the
                // prompt.
                await Task.detached(priority: .utility) {
                    _ = FileManager.default.containerURL(
                        forSecurityApplicationGroupIdentifier: appGroupId)
                }.value
            },
            needsRecycle: trigger.needsRecycle,
            isTranslocated: { AppTranslocation.isTranslocated(bundleURL) },
            recycleCompleted: trigger.recycleCompleted,
            openSettings: {
                SMAppService.openSystemSettingsLoginItems()
            })
    }

    nonisolated static let recycleStampKey = "org.librescrs.LibreMac.registeredAgentStamp"

    /// What identifies the agent and prompter this bundle would launch: the
    /// bundle version plus the host bundle's own code directory hash. The
    /// version alone is not enough — a rebuilt bundle dropped over the old one
    /// keeps its `CFBundleVersion`, and launchd would go on running the
    /// previous agent. Nor are the agent's and prompter's own hashes: most of
    /// the agent's code lives in the libraries and plugins beside it, which a
    /// rebuild can change under a byte-identical agent. The host is signed
    /// last, and its code directory seals every nested file — the programs
    /// under `Contents/MacOS`, `Contents/Frameworks`, `Contents/PlugIns` — so
    /// any of them changing changes it. An unreadable hash contributes `-`.
    nonisolated static func bundleStamp(
        bundleVersion: String, bundleURL: URL,
        codeHash: (URL) -> String? = codeDirectoryHash
    ) -> String {
        "\(bundleVersion)|\(codeHash(bundleURL) ?? "-")"
    }

    /// The code directory hash (CDHash) of the signed code at `url` (a program
    /// or a bundle), hex, or nil when it is missing or unsigned. Any rebuild
    /// or re-sign changes it, and it is read from the signature without
    /// hashing the whole code.
    nonisolated static func codeDirectoryHash(_ url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
            let dict = info as? [String: Any],
            let unique = dict[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// The recycle decision over a persisted stamp: recycle (unregister() +
    /// register()) only when the stored stamp differs from `stamp`, so a
    /// plain no-op register() leaves a healthy, already running agent
    /// untouched (an unconditional recycle would tear a serving agent down
    /// on every host launch).
    ///
    /// The stamp is recorded only in `recycleCompleted`, after every service
    /// survived the recycle — recording inside `needsRecycle` would let a
    /// register() failure leave a matching stamp, so the next launch would
    /// skip the recycle and the stale launch constraint would persist.
    ///
    /// KNOWN FOLLOW-UP (Developer ID build): a fresh registration's first
    /// RunAtLoad spawn can race an async launch-constraint computation and
    /// die EX_CONFIG; a stamp-gated recycle does not recover that on the next
    /// launch. The robust recovery is reachability-driven — recycle only if
    /// the client cannot reach the agent after a grace period — which needs
    /// the composition root to feed the client's availability back here.
    nonisolated static func recycleTrigger(
        suiteName: String, stamp: String
    ) -> (needsRecycle: @Sendable () -> Bool, recycleCompleted: @Sendable () -> Void) {
        let key = recycleStampKey
        return (
            needsRecycle: {
                let defaults = UserDefaults(suiteName: suiteName) ?? .standard
                return defaults.string(forKey: key) != stamp
            },
            recycleCompleted: {
                let defaults = UserDefaults(suiteName: suiteName) ?? .standard
                defaults.set(stamp, forKey: key)
            }
        )
    }
}

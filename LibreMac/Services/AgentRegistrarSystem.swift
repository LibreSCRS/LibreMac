// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The production wiring for `AgentRegistrar`: the concrete `SMAppService`
// LaunchAgent adapter and the composition-root factory. Isolated from
// `AgentRegistrar.swift` so the state-machine file imports no
// `ServiceManagement` and stays trivially unit-testable.

import Foundation
import LibreMacShared
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

extension AgentRegistrar {

    /// Builds the production registrar: the agent + prompter LaunchAgents, the
    /// off-main App-Group container materializer, a bundle-version-based
    /// recycle trigger (a proxy for "the bundled binary changed" — a host
    /// update ships a new agent binary), and the Login Items opener.
    public static func system(
        appGroupId: String = AppGroupConstants.appGroupId,
        bundleVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    ) -> AgentRegistrar {
        let versionKey = "org.librescrs.LibreMac.registeredBundleVersion"
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
            needsRecycle: {
                // Recycle (unregister()+register()) only when the bundled
                // binary changed: a host update carries a new agent/prompter
                // binary, so refresh the captured launch constraint then;
                // otherwise a plain no-op register() leaves a healthy, already
                // running agent untouched (an unconditional recycle would
                // tear a serving agent down on every host launch).
                //
                // KNOWN FOLLOW-UP (Developer ID build): a fresh registration's
                // first RunAtLoad spawn can race an async launch-constraint
                // computation and die EX_CONFIG; a version-gated recycle does
                // not recover that on the next launch. The robust recovery is
                // reachability-driven — recycle only if the client cannot
                // reach the agent after a grace period — which needs the
                // composition root to feed the client's availability back
                // here. Deferred to the signed build where it is verifiable;
                // the EX_CONFIG wedge seen on the ad-hoc dev machine was
                // compounded by stale BTM registrations, not this gate alone.
                let defaults = UserDefaults(suiteName: appGroupId) ?? .standard
                return defaults.string(forKey: versionKey) != bundleVersion
            },
            recycleCompleted: {
                // Recorded only HERE, after every service survived the
                // recycle — recording inside `needsRecycle` would let a
                // register() failure leave a matching stored version, so the
                // next launch would skip the recycle and the stale launch
                // constraint would persist until the next version bump.
                let defaults = UserDefaults(suiteName: appGroupId) ?? .standard
                defaults.set(bundleVersion, forKey: versionKey)
            },
            openSettings: {
                SMAppService.openSystemSettingsLoginItems()
            })
    }
}

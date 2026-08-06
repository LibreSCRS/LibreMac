// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Registers the per-user agent and its secure-entry prompter as
// `SMAppService` LaunchAgents, and drives the approval UX when macOS gates
// them behind System Settings › Login Items. `SMAppService` is not directly
// mockable, so the whole surface this registrar depends on sits behind the
// `LaunchAgentRegistering` protocol seam — the concrete `SMAppService`-backed
// implementation is `SMAppServiceAgent` below, and the state machine is
// exercised in tests with a scripted in-memory fake.
//
// Platform invariants that bind this:
//   - The first App-Group container touch TCC-prompts and BLOCKS, so it is
//     materialized off the main actor before any registration.
//   - Two services are registered, not one: the agent AND the prompter.
//   - Re-register-on-launch (FB22701547) must be a full unregister()+register()
//     RECYCLE when the bundled binary changed (or on a spawn-failure EX_CONFIG
//     detection) — a plain register() over an already-`enabled` service does
//     NOT refresh the captured launch constraint.

import Foundation
import LibreMacShared
import Observation
import os

/// The `SMAppService.Status` values this registrar reasons about, lifted
/// behind the seam so the state machine never imports `ServiceManagement`.
public enum LaunchAgentStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// The narrow slice of `SMAppService` the registrar drives. Injected so the
/// state machine is testable (`SMAppService` cannot be subclassed or mocked).
public protocol LaunchAgentRegistering: Sendable {
    /// A stable label for logging/diagnostics (the plist basename).
    var label: String { get }
    /// The service's current registration status.
    func status() -> LaunchAgentStatus
    /// Enable the LaunchAgent (idempotent for an already-enabled service, but
    /// does NOT refresh a stale launch constraint — see the recycle path).
    func register() throws
    /// Disable the LaunchAgent.
    func unregister() throws
}

/// Observable registrar that both host launch and the UI read: `state`
/// drives whether the menu shows an "Approve in System Settings…" affordance.
@MainActor
@Observable
public final class AgentRegistrar {

    /// Aggregate registration state across both services.
    public enum State: Sendable, Equatable {
        /// Not started yet.
        case idle
        /// Materializing the container / registering.
        case working
        /// At least one service needs the user's approval in Login Items.
        case requiresApproval
        /// Both services are enabled.
        case registered
        /// Registration failed; payload is a diagnostic (not user copy).
        case failed(String)
    }

    public private(set) var state: State = .idle

    private let services: [LaunchAgentRegistering]
    private let materializeContainer: @Sendable () async -> Void
    private let needsRecycle: @Sendable () -> Bool
    private let recycleCompleted: @Sendable () -> Void
    private let openSettings: @Sendable () -> Void

    /// Designated initializer — every collaborator injected (constructor DI,
    /// no global state).
    ///
    /// - Parameters:
    ///   - services: the LaunchAgents to keep registered (agent + prompter).
    ///   - materializeContainer: forces the App-Group container into existence
    ///     OFF the main actor (the first touch TCC-prompts and blocks).
    ///   - needsRecycle: `true` when the bundled binary changed or a prior
    ///     spawn failed `EX_CONFIG` — triggers a full unregister()+register()
    ///     rather than a no-op register().
    ///   - recycleCompleted: called once EVERY service survived the recycle —
    ///     the only point at which the trigger's bookkeeping (e.g. a persisted
    ///     bundle version) may be updated. Recording earlier would make the
    ///     next launch see a matching version after a failed recycle and never
    ///     refresh the stale launch constraint until the next version bump.
    ///   - openSettings: opens System Settings › Login Items (the approval UX).
    public init(
        services: [LaunchAgentRegistering],
        materializeContainer: @escaping @Sendable () async -> Void,
        needsRecycle: @escaping @Sendable () -> Bool,
        recycleCompleted: @escaping @Sendable () -> Void = {},
        openSettings: @escaping @Sendable () -> Void
    ) {
        self.services = services
        self.materializeContainer = materializeContainer
        self.needsRecycle = needsRecycle
        self.recycleCompleted = recycleCompleted
        self.openSettings = openSettings
    }

    /// Runs the launch flow: materialize the container off-main, then ensure
    /// every service is registered (recycling any whose captured launch
    /// constraint is stale), and publish the aggregate `state`.
    public func activate() async {
        state = .working
        await materializeContainer()
        let recycle = needsRecycle()
        for service in services {
            do {
                try ensure(service, recycle: recycle)
            } catch {
                Logger.agent.error(
                    "registration failed for \(service.label, privacy: .public): \(error.localizedDescription, privacy: .public)")
                state = .failed("\(service.label): \(error.localizedDescription)")
                return
            }
        }
        if recycle {
            recycleCompleted()
        }
        state = aggregateState()
    }

    /// Opens System Settings › Login Items so the user can approve a service
    /// currently in `requiresApproval`.
    public func openLoginItemsSettings() {
        openSettings()
    }

    // MARK: - State machine (the test subject)

    private func ensure(_ service: LaunchAgentRegistering, recycle: Bool) throws {
        if recycle {
            // Full recycle: a plain register() over an `enabled` service does
            // not refresh a stale launch constraint. unregister() may
            // legitimately fail for a not-yet-registered service — that is not
            // fatal, so it is best-effort; the following register() is not.
            try? service.unregister()
            try service.register()
            return
        }
        switch service.status() {
        case .notRegistered, .notFound:
            try service.register()
        case .requiresApproval, .enabled:
            break
        }
    }

    private func aggregateState() -> State {
        let statuses = services.map { $0.status() }
        if statuses.contains(.requiresApproval) {
            return .requiresApproval
        }
        if statuses.allSatisfy({ $0 == .enabled }) {
            return .registered
        }
        // Registered but the OS has not yet moved them to `enabled` — keep the
        // UI in a neutral "working" state rather than claiming success.
        return .working
    }
}

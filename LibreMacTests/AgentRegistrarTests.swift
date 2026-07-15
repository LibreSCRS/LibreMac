// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// State-machine tests for AgentRegistrar via the `LaunchAgentRegistering`
// protocol seam (SMAppService itself is not mockable). The scripted fake
// records register()/unregister() calls and advances its own status, so the
// recycle-vs-register decision and the aggregate-state derivation are exercised
// without touching the real launchd.

import Foundation
import Testing
@testable import LibreMac

/// Scriptable stand-in for one `SMAppService`-backed LaunchAgent.
final class FakeLaunchAgent: LaunchAgentRegistering, @unchecked Sendable {
    let label: String
    private let lock = NSLock()
    private var currentStatus: LaunchAgentStatus
    private let statusAfterRegister: LaunchAgentStatus
    private let registerError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(
        label: String,
        status: LaunchAgentStatus,
        statusAfterRegister: LaunchAgentStatus = .enabled,
        registerError: Error? = nil
    ) {
        self.label = label
        self.currentStatus = status
        self.statusAfterRegister = statusAfterRegister
        self.registerError = registerError
    }

    func status() -> LaunchAgentStatus {
        lock.lock(); defer { lock.unlock() }
        return currentStatus
    }

    func register() throws {
        if let registerError { throw registerError }
        lock.lock(); defer { lock.unlock() }
        registerCount += 1
        currentStatus = statusAfterRegister
    }

    func unregister() throws {
        lock.lock(); defer { lock.unlock() }
        unregisterCount += 1
        currentStatus = .notRegistered
    }
}

struct RegistrarTestError: Error {}

@Suite("AgentRegistrar")
@MainActor
struct AgentRegistrarTests {

    private func makeRegistrar(
        services: [FakeLaunchAgent], recycle: Bool
    ) -> AgentRegistrar {
        AgentRegistrar(
            services: services,
            materializeContainer: {},
            needsRecycle: { recycle },
            openSettings: {})
    }

    @Test("not-registered services are registered and end enabled")
    func registersFromNotRegistered() async {
        let agent = FakeLaunchAgent(label: "agent", status: .notRegistered)
        let prompter = FakeLaunchAgent(label: "prompter", status: .notRegistered)
        let registrar = makeRegistrar(services: [agent, prompter], recycle: false)

        await registrar.activate()

        #expect(agent.registerCount == 1)
        #expect(prompter.registerCount == 1)
        #expect(registrar.state == .registered)
    }

    @Test("requiresApproval surfaces the approval state and does not register")
    func requiresApprovalSurfaces() async {
        let agent = FakeLaunchAgent(label: "agent", status: .requiresApproval)
        let prompter = FakeLaunchAgent(label: "prompter", status: .enabled)
        let registrar = makeRegistrar(services: [agent, prompter], recycle: false)

        await registrar.activate()

        #expect(agent.registerCount == 0)
        #expect(registrar.state == .requiresApproval)
    }

    @Test("recycle forces a full unregister()+register() even when enabled")
    func recycleRecyclesEnabledService() async {
        let agent = FakeLaunchAgent(label: "agent", status: .enabled)
        let prompter = FakeLaunchAgent(label: "prompter", status: .enabled)
        let registrar = makeRegistrar(services: [agent, prompter], recycle: true)

        await registrar.activate()

        #expect(agent.unregisterCount == 1)
        #expect(agent.registerCount == 1)
        #expect(prompter.unregisterCount == 1)
        #expect(prompter.registerCount == 1)
        #expect(registrar.state == .registered)
    }

    @Test("a register failure surfaces as failed state")
    func registerFailureSurfaces() async {
        let agent = FakeLaunchAgent(
            label: "agent", status: .notRegistered, registerError: RegistrarTestError())
        let registrar = makeRegistrar(services: [agent], recycle: false)

        await registrar.activate()

        if case .failed = registrar.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(registrar.state)")
        }
    }
}

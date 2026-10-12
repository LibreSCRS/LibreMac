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

/// Thread-safe call counter for the `recycleCompleted` callback.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite("AgentRegistrar")
@MainActor
struct AgentRegistrarTests {

    private func makeRegistrar(
        services: [FakeLaunchAgent], recycle: Bool,
        recycleCompleted: @escaping @Sendable () -> Void = {}
    ) -> AgentRegistrar {
        AgentRegistrar(
            services: services,
            materializeContainer: {},
            needsRecycle: { recycle },
            recycleCompleted: recycleCompleted,
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

    @Test("a successful recycle records its completion exactly once")
    func successfulRecycleRecordsCompletion() async {
        let agent = FakeLaunchAgent(label: "agent", status: .enabled)
        let completions = CallCounter()
        let registrar = makeRegistrar(
            services: [agent], recycle: true, recycleCompleted: { completions.record() })

        await registrar.activate()

        #expect(completions.callCount == 1)
        #expect(registrar.state == .registered)
    }

    @Test("a failed recycle does not record completion, so the next launch recycles again")
    func failedRecycleDoesNotRecordCompletion() async {
        let agent = FakeLaunchAgent(
            label: "agent", status: .enabled, registerError: RegistrarTestError())
        let completions = CallCounter()
        let registrar = makeRegistrar(
            services: [agent], recycle: true, recycleCompleted: { completions.record() })

        await registrar.activate()

        #expect(completions.callCount == 0)
        if case .failed = registrar.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(registrar.state)")
        }
    }

    @Test("a non-recycle activation never reports a recycle completion")
    func nonRecycleActivationDoesNotRecordCompletion() async {
        let agent = FakeLaunchAgent(label: "agent", status: .enabled)
        let completions = CallCounter()
        let registrar = makeRegistrar(
            services: [agent], recycle: false, recycleCompleted: { completions.record() })

        await registrar.activate()

        #expect(completions.callCount == 0)
    }

    @Test("a translocated host registers nothing and never touches the container")
    func translocatedRegistersNothing() async {
        let agent = FakeLaunchAgent(label: "agent", status: .notRegistered)
        let prompter = FakeLaunchAgent(label: "prompter", status: .notRegistered)
        let touched = CallCounter()
        let registrar = AgentRegistrar(
            services: [agent, prompter],
            materializeContainer: { touched.record() },
            needsRecycle: { true },
            isTranslocated: { true },
            openSettings: {})
        await registrar.activate()
        #expect(registrar.state == .translocated)
        #expect(agent.registerCount == 0 && agent.unregisterCount == 0)
        #expect(prompter.registerCount == 0 && prompter.unregisterCount == 0)
        #expect(touched.callCount == 0)
    }

    @Test("a host in place registers as before")
    func notTranslocatedRegisters() async {
        let agent = FakeLaunchAgent(label: "agent", status: .notRegistered)
        let registrar = AgentRegistrar(
            services: [agent], materializeContainer: {}, needsRecycle: { false },
            isTranslocated: { false }, openSettings: {})
        await registrar.activate()
        #expect(registrar.state == .registered)
        #expect(agent.registerCount == 1)
    }
}

/// The production recycle trigger: what is stamped, and when a stamp change
/// turns into a recycle.
@Suite("AgentRegistrar recycle trigger")
@MainActor
struct AgentRecycleTriggerTests {

    private let agentURL = URL(fileURLWithPath: "/Applications/X.app/Contents/MacOS/librescrs-agent")
    private let prompterURL = URL(fileURLWithPath: "/Applications/X.app/Contents/MacOS/librescrs-prompter")

    private func stamp(version: String, agentHash: String) -> String {
        AgentRegistrar.bundleStamp(
            bundleVersion: version, programs: [agentURL, prompterURL],
            codeHash: { $0 == agentURL ? agentHash : "prompter-hash" })
    }

    /// A defaults suite private to one test, removed afterwards.
    private func withScratchSuite(_ body: (String) async throws -> Void) async rethrows {
        let suite = "org.librescrs.LibreMac.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try await body(suite)
    }

    @Test("same version, different agent binary: stamps differ")
    func sameVersionDifferentBinary() {
        #expect(stamp(version: "5.0.0", agentHash: "aa") != stamp(version: "5.0.0", agentHash: "bb"))
        #expect(stamp(version: "5.0.0", agentHash: "aa") == stamp(version: "5.0.0", agentHash: "aa"))
        #expect(stamp(version: "5.0.0", agentHash: "aa") != stamp(version: "5.0.1", agentHash: "aa"))
    }

    @Test("a same-version bundle with a new agent binary recycles once, then not again")
    func sameVersionNewBinaryRecycles() async {
        await withScratchSuite { suite in
            let before = AgentRegistrar.recycleTrigger(
                suiteName: suite, stamp: stamp(version: "5.0.0", agentHash: "aa"))
            before.recycleCompleted()

            let replaced = AgentRegistrar.recycleTrigger(
                suiteName: suite, stamp: stamp(version: "5.0.0", agentHash: "bb"))
            let agent = FakeLaunchAgent(label: "agent", status: .enabled)
            let registrar = AgentRegistrar(
                services: [agent], materializeContainer: {},
                needsRecycle: replaced.needsRecycle,
                recycleCompleted: replaced.recycleCompleted, openSettings: {})
            await registrar.activate()
            #expect(agent.unregisterCount == 1)
            #expect(agent.registerCount == 1)

            // Next launch of the same bundle: nothing to refresh.
            await registrar.activate()
            #expect(agent.unregisterCount == 1)
            #expect(agent.registerCount == 1)
        }
    }

    @Test("an unchanged bundle does not recycle")
    func unchangedBundleDoesNotRecycle() async {
        await withScratchSuite { suite in
            let current = stamp(version: "5.0.0", agentHash: "aa")
            AgentRegistrar.recycleTrigger(suiteName: suite, stamp: current).recycleCompleted()
            let trigger = AgentRegistrar.recycleTrigger(suiteName: suite, stamp: current)
            #expect(trigger.needsRecycle() == false)
        }
    }

    @Test("code directory hash tells signed programs apart and is nil for a missing one")
    func codeDirectoryHashOfRealPrograms() {
        let ls = AgentRegistrar.codeDirectoryHash(URL(fileURLWithPath: "/bin/ls"))
        let cat = AgentRegistrar.codeDirectoryHash(URL(fileURLWithPath: "/bin/cat"))
        #expect(ls != nil)
        #expect(cat != nil)
        #expect(ls != cat)
        #expect(ls == AgentRegistrar.codeDirectoryHash(URL(fileURLWithPath: "/bin/ls")))
        #expect(AgentRegistrar.codeDirectoryHash(URL(fileURLWithPath: "/nonexistent/librescrs-agent")) == nil)
    }
}

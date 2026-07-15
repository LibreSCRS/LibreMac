// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import Testing
@testable import LibreMacAgentClient

/// A tiny thread-safe counter — used instead of capturing a mutable local
/// `var` in a `@Sendable` closure (which Swift 6 strict concurrency
/// rejects regardless of any manual locking around the capture site).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("OperationDriver")
struct OperationDriverTests {

    @Test("a stall while in a machine phase cancels the operation and surfaces .watchdogTimeout")
    func stallSurfacesWatchdogTimeout() async {
        let cancelCount = CallCounter()
        let operation = AgentOperation(id: 1, kind: .readIdentity) {
            cancelCount.increment()
        }
        operation.publishPhase(.reading, progress: nil)
        // Never publish another phase and never resolveFinished — this
        // operation is stuck in a "machine" phase forever, from the
        // driver's point of view.

        let driver = OperationDriver()
        let (status, code, msgKey, _) = await driver.driveToFinished(operation, stallTimeout: 0.2)

        #expect(status == .cancelled)
        #expect(code == .watchdogTimeout)
        #expect(msgKey == nil)
        #expect(cancelCount.read() == 1)
    }

    @Test("the stall timer is stopped during awaitingConsent/authenticating and re-armed on machine phases")
    func stallTimerIsPhaseAware() async {
        let operation = AgentOperation(id: 2, kind: .sign) {}
        operation.publishPhase(.connecting, progress: nil)

        let driver = OperationDriver()
        async let driven = driver.driveToFinished(operation, stallTimeout: 0.15)

        // Sit in awaitingConsent for LONGER than stallTimeout — must NOT
        // trip the watchdog while the phase is exempt.
        operation.publishPhase(.awaitingConsent, progress: nil)
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms > the 150ms stallTimeout

        // Same for authenticating.
        operation.publishPhase(.authenticating, progress: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Re-arm on a machine phase, then finish immediately — well
        // inside the re-armed stall window.
        operation.publishPhase(.reading, progress: nil)
        operation.resolveFinished((.ok, .none, nil, "done"))

        let (status, code, _, msgFallback) = await driven
        #expect(status == .ok)
        #expect(code == .none)
        #expect(msgFallback == "done")
    }

    @Test("finishing well inside stallTimeout never trips the watchdog")
    func noStallWhenFinishingBeforeTimeout() async {
        let operation = AgentOperation(id: 3, kind: .getPhoto) {}
        operation.publishPhase(.reading, progress: nil)

        let driver = OperationDriver()
        async let driven = driver.driveToFinished(operation, stallTimeout: 1.0)
        operation.resolveFinished((.ok, .none, nil, "ok"))

        let (status, code, _, _) = await driven
        #expect(status == .ok)
        #expect(code == .none)
    }
}

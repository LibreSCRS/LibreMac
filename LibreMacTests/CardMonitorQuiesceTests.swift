// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

// How CardMonitor follows the agent's quiesces: a reason is recorded when the
// agent announces it and forgotten when the agent announces its end, the card
// surface stays quiesced while any reason is left, a registry snapshot does not
// end one, and a lost agent ends all of them. The client behind the monitor
// listens on a socket nobody owns, so no event arrives but the ones a test
// hands it.

import Foundation
import Testing
@testable import LibreMacAgentClient
@testable import LibreMac

@MainActor
private func waitUntil(
    timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

@Suite("CardMonitor quiesce")
@MainActor
struct CardMonitorQuiesceTests {

    private func makeMonitor() -> (CardMonitor, AgentClient) {
        let client = AgentClient(socketPath: "/nonexistent/librescrs-test.sock")
        let monitor = CardMonitor(client: client)
        monitor.apply(available: true, features: [])
        return (monitor, client)
    }

    @Test("a lock that outlasts a wake keeps the surface quiesced until the unlock")
    func overlappingReasons() {
        let (monitor, _) = makeMonitor()
        monitor.apply(quiesced: .screenLocked)
        monitor.apply(quiesced: .systemSleep)
        #expect(monitor.presence == .quiesced(.screenLocked))
        monitor.apply(resumed: .systemSleep)
        #expect(monitor.presence == .quiesced(.screenLocked), "the lock is still on")
        monitor.apply(resumed: .screenLocked)
        #expect(monitor.presence == .noReader, "the unlock ended the last reason")
    }

    @Test("an end for a reason never announced changes nothing")
    func strayEnd() {
        let (monitor, _) = makeMonitor()
        monitor.apply(quiesced: .screenLocked)
        monitor.apply(resumed: .systemSleep)
        #expect(monitor.presence == .quiesced(.screenLocked))
    }

    @Test("a registry snapshot no longer ends a quiesce")
    func snapshotKeepsTheQuiesce() {
        let (monitor, _) = makeMonitor()
        monitor.apply(quiesced: .systemSleep)
        monitor.apply(snapshot: RegistrySnapshot(readers: [], cards: []))
        #expect(monitor.presence == .quiesced(.systemSleep))
    }

    @Test("losing the agent ends every quiesce it announced")
    func lostAgentClearsTheReasons() {
        let (monitor, _) = makeMonitor()
        monitor.apply(quiesced: .screenLocked)
        monitor.apply(available: false, features: [])
        #expect(monitor.presence == .agentUnavailable)
        monitor.apply(available: true, features: [])
        #expect(monitor.presence == .noReader, "a restarted agent owes no end for the old one's quiesce")
    }

    @Test("the client's quiescence and resumption streams reach the monitor")
    func streamsReachTheMonitor() async {
        let (monitor, client) = makeMonitor()
        await client.handleEvent(.agentQuiesced(reason: .screenLocked), fds: [])
        #expect(await waitUntil { monitor.presence == .quiesced(.screenLocked) })
        await client.handleEvent(.agentResumed(reason: .screenLocked), fds: [])
        #expect(await waitUntil { monitor.presence == .noReader }, "the end arrives on resumption")
    }
}

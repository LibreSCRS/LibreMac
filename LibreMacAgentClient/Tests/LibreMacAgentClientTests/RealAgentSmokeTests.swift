// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

// Cross-implementation live-agent smoke test — OPT-IN, env-gated.
//
// Every `@Test` in this suite is SKIPPED unless `LIBRESCRS_AGENT_SOCK` is set
// to a real running agent's Unix-domain socket path. With the variable
// unset — the default for `swift test` and CI — the suite reports as
// skipped and the overall run stays green. This is deliberate: unlike
// `CrossImplementationFixtureTests.swift` (which decodes canned `.cbor`
// bytes captured ahead of time from the C++ encoder), this suite drives an
// actual `AgentClient` against an actual `librescrs-agent` process over a
// real socket — the one place the Swift wire codec (`Messages.swift`,
// `CanonicalCBOR.swift`) is checked against the live C++ QCBOR encoder/
// decoder rather than a fixture snapshot. No card or reader is required —
// an empty reader list from `GetState` is a PASS.
//
// To run against a real locally built LibreDarwin agent. The agent takes no
// socket or container override: it always binds agent.sock in the App-Group
// container, the same socket an installed agent serves. So stop the installed
// one first -- otherwise the one started here unlinks and re-binds the socket
// under it -- and re-register it afterwards:
//
//   launchctl bootout "gui/$UID/org.librescrs.agent" 2>/dev/null || true
//   SOCK="$HOME/Library/Group Containers/group.org.librescrs.LibreMac/agent.sock"
//   /path/to/LibreDarwin/build-release/agent/librescrs-agent &
//   AGENT_PID=$!
//   for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
//   LIBRESCRS_AGENT_SOCK="$SOCK" \
//     swift test --package-path LibreMac/LibreMacAgentClient --filter RealAgentSmoke
//   kill "$AGENT_PID"
//   # re-register the installed agent (the host app, or LibreDarwin's
//   # packaging/install-dev.sh launchd for a development agent)
//
// The wait is bounded: an agent that fails to start is a failed run, not a
// shell that waits forever. No plugin directory is needed; the smoke never
// asks for a card.
//
// The prompter socket is not needed for this smoke — Hello, GetState, and
// GetConfig never reach the prompter or PC/SC.

import Foundation
import Testing
@testable import LibreMacAgentClient

/// Reads `LIBRESCRS_AGENT_SOCK` directly (not `AgentSocketPath.resolve()`,
/// which also falls back to the App-Group container) — this suite's whole
/// point is to be a no-op unless a real socket was explicitly handed to it.
private func liveAgentSocketPath() -> String? {
    let value = ProcessInfo.processInfo.environment[AgentSocketPath.environmentOverrideKey]
    return (value?.isEmpty == false) ? value : nil
}

@Suite(
    "RealAgentSmoke",
    .enabled(
        if: liveAgentSocketPath() != nil,
        "set LIBRESCRS_AGENT_SOCK to a running agent's socket path to run this suite"))
struct RealAgentSmokeTests {

    /// Starts a real `AgentClient` against the live socket and polls
    /// `isAvailable()` up to `timeout` — the connect + Hello + GetState
    /// handshake is fast against a local agent, but this avoids a fixed
    /// sleep as synchronization.
    private func connectedClient(timeout: TimeInterval = 5.0) async throws -> AgentClient {
        let socketPath = try #require(liveAgentSocketPath())
        let client = AgentClient(socketPath: socketPath, clientVersion: "LibreMac/RealAgentSmoke")
        await client.start()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await client.isAvailable() {
                return client
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await client.stop()
        Issue.record("agent never became available within \(timeout)s at \(socketPath)")
        throw AgentClientError.notConnected
    }

    @Test("Hello/HelloAck over the real socket: agent version and features populate")
    func helloHandshakeAgainstRealAgent() async throws {
        let client = try await connectedClient()

        let info = await client.agentInfo()
        let version = try #require(info.version)
        #expect(!version.isEmpty)
        #expect(!info.features.isEmpty, "the real agent always advertises a non-empty feature list")

        await client.stop()
    }

    @Test("GetState over the real socket: readers list is retrievable (empty is a PASS — no card required)")
    func getStateAgainstRealAgent() async throws {
        let client = try await connectedClient()

        // GetState already ran as part of the connect handshake; readers()
        // returns whatever it populated. An empty list is a legitimate,
        // expected PASS in a card-free environment — this asserts the call
        // path decoded successfully, not that a card is present.
        let readers = await client.readers()
        #expect(readers.allSatisfy { !$0.handle.isEmpty })

        await client.stop()
    }

    @Test("GetConfig over the real socket: typed config entries decode")
    func getConfigAgainstRealAgent() async throws {
        let client = try await connectedClient()

        let entries = try await client.getConfig()
        #expect(!entries.isEmpty, "the real agent always reports a fixed set of config keys")
        // Every value decoded into the typed `CBORValue` wire representation
        // (not raw bytes) — pin the one key the agent always sets.
        if let defaultLevel = entries["DefaultLevel"] {
            guard case .text(let level) = defaultLevel else {
                Issue.record("expected DefaultLevel to decode as CBORValue.text, got \(defaultLevel)")
                return
            }
            #expect(!level.isEmpty)
        } else {
            Issue.record("expected a DefaultLevel entry in GetConfig's reply")
        }

        await client.stop()
    }
}

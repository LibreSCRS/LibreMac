// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import Testing
@testable import LibreMacAgentClient

// `resolve()`'s env-var override is tested against the REAL process
// environment (via setenv/unsetenv) rather than a mock. The
// containerURL-vs-HOME fallback ordering is exercised through the
// `environment`/`containerURL` injectable seams instead of the real
// `FileManager` call: whether `containerURL(forSecurityApplicationGroupIdentifier:)`
// resolves depends on ambient, machine-specific state (an installed
// LibreMac.app's App Group container) that a test must not depend on to be
// deterministic in CI.
//
// Real-`setenv` tests run serialized (`.serialized`) — mutating process-wide
// environment state is not safe to interleave with Swift Testing's default
// parallel test execution within a suite.
@Suite("AgentSocketPath", .serialized)
struct AgentSocketPathTests {

    @Test("LIBRESCRS_AGENT_SOCK env override takes priority (real setenv)")
    func realEnvOverrideTakesPriority() {
        let overridePath = "/tmp/librescrs-agentclient-test-override.sock"
        setenv(AgentSocketPath.environmentOverrideKey, overridePath, 1)
        defer { unsetenv(AgentSocketPath.environmentOverrideKey) }

        #expect(AgentSocketPath.resolve() == overridePath)
    }

    @Test("an empty env override is treated as unset")
    func emptyEnvOverrideIsIgnored() {
        let resolved = AgentSocketPath.resolve(
            environment: [AgentSocketPath.environmentOverrideKey: "", "HOME": "/Users/test"],
            containerURL: { _ in nil }
        )
        #expect(resolved == "/Users/test/Library/Group Containers/group.org.librescrs.LibreMac/agent.sock")
    }

    @Test("uses the App Group container path when it resolves")
    func usesContainerURLWhenAvailable() {
        let containerPath = "/Users/test/Library/Group Containers/group.org.librescrs.LibreMac"
        let resolved = AgentSocketPath.resolve(
            environment: [:],
            containerURL: { identifier in
                #expect(identifier == AgentSocketPath.appGroupIdentifier)
                return URL(fileURLWithPath: containerPath, isDirectory: true)
            }
        )
        #expect(resolved == "\(containerPath)/agent.sock")
    }

    @Test("falls back to $HOME/Library/Group Containers/<group>/agent.sock when the container does not resolve")
    func fallsBackToHomeWhenContainerURLIsNil() {
        let resolved = AgentSocketPath.resolve(
            environment: ["HOME": "/Users/test"],
            containerURL: { _ in nil }
        )
        #expect(resolved == "/Users/test/Library/Group Containers/group.org.librescrs.LibreMac/agent.sock")
    }

    @Test("the env override wins even when the container would resolve")
    func envOverrideWinsOverContainerURL() {
        let resolved = AgentSocketPath.resolve(
            environment: [AgentSocketPath.environmentOverrideKey: "/tmp/injected-override.sock"],
            containerURL: { _ in URL(fileURLWithPath: "/Users/test/Library/Group Containers/group.org.librescrs.LibreMac") }
        )
        #expect(resolved == "/tmp/injected-override.sock")
    }

    @Test("falls back to NSHomeDirectory() when HOME is absent from the environment")
    func fallsBackToNSHomeDirectoryWhenHomeIsUnset() {
        let resolved = AgentSocketPath.resolve(
            environment: [:],
            containerURL: { _ in nil }
        )
        #expect(resolved == "\(NSHomeDirectory())/Library/Group Containers/group.org.librescrs.LibreMac/agent.sock")
    }
}

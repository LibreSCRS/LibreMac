// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import Testing
@testable import LibreMacAgentClient

// That the environment cannot move the socket is tested against the REAL
// process environment (via setenv/unsetenv) as well as through the seam. The
// container / user database / HOME fallback ordering is exercised through the
// `environment`/`accountHome`/`containerURL` injectable seams instead of the real
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

    @Test("without a team the App Group keeps the group. prefix")
    func appGroupWithoutTeam() {
        #expect(AgentSocketPath.appGroup(forTeam: nil) == "group.org.librescrs.LibreMac")
        #expect(AgentSocketPath.appGroup(forTeam: "") == "group.org.librescrs.LibreMac")
    }

    @Test("with a team the App Group is named after it")
    func appGroupWithTeam() {
        #expect(AgentSocketPath.appGroup(forTeam: "ABCDE12345") == "ABCDE12345.org.librescrs.LibreMac")
    }

    /// The agent binds only the App Group container; a socket path taken from
    /// the environment could only lead a shipped client to another process.
    @Test("a socket path in the environment does not move the client (real setenv)")
    func realEnvironmentSocketPathIsIgnored() {
        let injected = "/tmp/librescrs-agentclient-test-override.sock"
        setenv("LIBRESCRS_AGENT_SOCK", injected, 1)
        defer { unsetenv("LIBRESCRS_AGENT_SOCK") }

        #expect(AgentSocketPath.resolve() != injected)
        #expect(AgentSocketPath.resolve().hasSuffix("/\(AgentSocketPath.appGroupIdentifier)/agent.sock"))
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

    /// The fallback is the account's own directory: a `HOME` pointed
    /// elsewhere (a launcher, a wrapper script) must not move the client to
    /// a socket under another directory.
    @Test("the fallback takes the home directory from the user database, not from HOME")
    func fallbackHomeComesFromTheAccount() {
        // The plain call as the oracle: a different API from the one under test.
        let account = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        #expect(account != "/somewhere/else")
        #expect(AgentSocketPath.accountHomeDirectory() == account)
        let resolved = AgentSocketPath.resolve(
            environment: ["HOME": "/somewhere/else"],
            containerURL: { _ in nil }
        )
        #expect(resolved == "\(account)/Library/Group Containers/group.org.librescrs.LibreMac/agent.sock")
    }

    @Test("the account's home wins over HOME on the fallback")
    func accountHomeWinsOverHome() {
        let resolved = AgentSocketPath.resolve(
            environment: ["HOME": "/somewhere/else"],
            accountHome: { "/Users/account" },
            containerURL: { _ in nil }
        )
        #expect(resolved == "/Users/account/Library/Group Containers/group.org.librescrs.LibreMac/agent.sock")
    }

    @Test("falls back to $HOME when the user database has no home for the account")
    func fallsBackToHomeWhenTheDatabaseHasNone() {
        let resolved = AgentSocketPath.resolve(
            environment: ["HOME": "/Users/test"],
            accountHome: { nil },
            containerURL: { _ in nil }
        )
        #expect(resolved == "/Users/test/Library/Group Containers/group.org.librescrs.LibreMac/agent.sock")
    }

    @Test("a socket path in the environment is ignored when the container does not resolve either")
    func environmentSocketPathIsIgnoredOnTheFallback() {
        let resolved = AgentSocketPath.resolve(
            environment: ["LIBRESCRS_AGENT_SOCK": "/tmp/injected-override.sock", "HOME": "/Users/test"],
            accountHome: { nil },
            containerURL: { _ in nil }
        )
        #expect(resolved == "/Users/test/Library/Group Containers/group.org.librescrs.LibreMac/agent.sock")
    }

    @Test("falls back to NSHomeDirectory() when neither the database nor HOME names a home")
    func fallsBackToNSHomeDirectoryWhenHomeIsUnset() {
        let resolved = AgentSocketPath.resolve(
            environment: [:],
            accountHome: { nil },
            containerURL: { _ in nil }
        )
        #expect(resolved == "\(NSHomeDirectory())/Library/Group Containers/group.org.librescrs.LibreMac/agent.sock")
    }
}

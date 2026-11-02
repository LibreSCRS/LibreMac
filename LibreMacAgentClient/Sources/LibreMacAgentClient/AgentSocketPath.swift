// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation

/// Resolves the filesystem path of the LibreMac agent's Unix-domain
/// listening socket. The one place in this package that knows the
/// App-Group container name and the resolution order — every caller
/// (`SocketConnection.connect(path:)` and above) goes through
/// `AgentSocketPath.resolve()` rather than hardcoding a path.
///
/// Nothing in the environment moves it: the agent binds only the App Group
/// container, so a path taken from the environment can only lead a client
/// somewhere else. A test that needs another socket hands its path to the
/// client directly (`AgentClient(socketPath:)`, `TokenAgentClient(socketPath:)`).
public enum AgentSocketPath {

    // The three facts below are the agent's (`socket-location` in its wire
    // vocabulary manifest, vendored as `Contract/wire-vocabulary.json` and
    // read by the tests and by `Scripts/sign-bundle.sh`/`verify-bundle.sh`).

    /// The socket's file name inside the App Group container.
    public static let socketName = "agent.sock"

    /// What follows the team in the App Group name.
    public static let appGroupSuffix = ".org.librescrs.LibreMac"

    /// What stands in for the team when the build names none.
    public static let noTeamAppGroupPrefix = "group"

    /// The App Group shared by the host, its CTK extension and the agent: named
    /// after the signing team, because macOS 27 refuses an unprovisioned `group.`
    /// container to a sandboxed process. Without a team (CI, tests) it keeps `group.`.
    public static func appGroup(forTeam teamId: String?) -> String {
        guard let teamId, !teamId.isEmpty else { return noTeamAppGroupPrefix + appGroupSuffix }
        return teamId + appGroupSuffix
    }

    /// The App Group of this build, from the team in this process's Info.plist
    /// (`AgentPeerIdentity.configuredTeamId`).
    public static var appGroupIdentifier: String { appGroup(forTeam: AgentPeerIdentity.configuredTeamId) }

    /// Resolves the agent socket path, in this exact order:
    /// 1. The App Group container
    ///    (`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`)
    ///    plus `agent.sock`, when the container resolves — the path a
    ///    sandboxed process (the host, the CTK extension) reaches via the
    ///    `application-groups` entitlement.
    /// 2. `<home>/Library/Group Containers/<appGroupIdentifier>/agent.sock`
    ///    as a last resort — the SAME directory as (1), reached by its
    ///    well-known absolute path rather than the entitlement-gated API.
    ///    `<home>` is the account's home directory from the user database
    ///    (`accountHomeDirectory()`); `$HOME` counts only when the database
    ///    has no answer, so a redirected `HOME` cannot point the client at
    ///    another directory.
    ///    Every shipped process (host, CTK extension, bundled agent and
    ///    prompter) is sandboxed WITH the `application-groups` entitlement
    ///    (`Scripts/sign-bundle.sh` and `Packaging/entitlements/` are the signing source of truth), so
    ///    (1) resolves for all of them; this fallback exists for an
    ///    UNENTITLED context only — a dev-tree agent or client run outside
    ///    the signed bundle, which reaches the same per-user directory by
    ///    its absolute path.
    ///
    /// `environment`, `accountHome` and `containerURL` are injectable seams
    /// for tests; production callers use the defaults.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        accountHome: () -> String? = AgentSocketPath.accountHomeDirectory,
        containerURL: (String) -> URL? = { identifier in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        }
    ) -> String {
        if let container = containerURL(appGroupIdentifier) {
            return container.appendingPathComponent(socketName).path
        }
        let home = accountHome() ?? environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/Library/Group Containers/\(appGroupIdentifier)/\(socketName)"
    }

    /// This account's home directory from the user database, or nil when
    /// the database has no entry for the uid or names an empty directory.
    /// `getpwuid_r`, not `getpwuid`: clients resolve the path from more
    /// than one thread, and the plain call returns a shared static buffer.
    public static func accountHomeDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: 16384)
        return buffer.withUnsafeMutableBufferPointer { storage -> String? in
            var entry = passwd()
            var found: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &found) == 0, found != nil,
                let directory = entry.pw_dir, directory.pointee != 0
            else { return nil }
            return String(cString: directory)
        }
    }
}

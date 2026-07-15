// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Resolves the filesystem path of the LibreMac agent's Unix-domain
/// listening socket. The one place in this package that knows the
/// App-Group container name and the resolution order — every caller
/// (`SocketConnection.connect(path:)` and above) goes through
/// `AgentSocketPath.resolve()` rather than hardcoding a path.
public enum AgentSocketPath {

    /// Overrides resolution entirely when set to a non-empty value —
    /// primarily for tests and local development against a
    /// non-App-Group-installed agent.
    public static let environmentOverrideKey = "LIBRESCRS_AGENT_SOCK"

    /// The macOS App Group shared by the LibreMac host, its CTK extension,
    /// and the agent.
    public static let appGroupIdentifier = "group.org.librescrs.LibreMac"

    /// Resolves the agent socket path, in this exact order:
    /// 1. `LIBRESCRS_AGENT_SOCK`, if set to a non-empty value.
    /// 2. The App Group container
    ///    (`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`)
    ///    plus `agent.sock`, when the container resolves — the path a
    ///    sandboxed process (the host, the CTK extension) reaches via the
    ///    `application-groups` entitlement.
    /// 3. `$HOME/Library/Group Containers/group.org.librescrs.LibreMac/agent.sock`
    ///    as a last resort — the SAME directory as (2), reached by its
    ///    well-known absolute path rather than the entitlement-gated API.
    ///    This is how the non-sandboxed agent process (which owns and binds
    ///    the socket) finds it: it has no `application-groups` entitlement
    ///    of its own to resolve (2) with.
    ///
    /// `environment` and `containerURL` are injectable seams for tests;
    /// production callers use the defaults.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        containerURL: (String) -> URL? = { identifier in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        }
    ) -> String {
        if let override = environment[environmentOverrideKey], !override.isEmpty {
            return override
        }
        if let container = containerURL(appGroupIdentifier) {
            return container.appendingPathComponent("agent.sock").path
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/Library/Group Containers/\(appGroupIdentifier)/agent.sock"
    }
}

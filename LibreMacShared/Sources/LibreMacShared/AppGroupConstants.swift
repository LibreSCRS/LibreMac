// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Constants shared between the host app and the CTK appex. Centralised
/// so a typo in either process surfaces at compile time, not runtime.
public enum AppGroupConstants {
    public static let appGroupId = "group.org.librescrs.LibreMac"
    public static let preferencesSuiteName = "group.org.librescrs.LibreMac.preferences"

    public enum DefaultsKeys {
        public static let preferredLocale = "org.librescrs.LibreMac.preferredLocale"
        public static let logLevel = "org.librescrs.LibreMac.logLevel"
        /// Where signed files are offered by default. Client-local: the agent
        /// has no say in where this host puts a file it wrote.
        public static let defaultOutputFolder = "org.librescrs.LibreMac.defaultOutputFolder"
        /// Security-scoped bookmark for the folder above, stored when it is
        /// chosen with the panel. The path alone is not enough under the App
        /// Sandbox: the grant a panel gives ends with the process, and only
        /// the bookmark carries it across a relaunch.
        public static let defaultOutputFolderBookmark =
            "org.librescrs.LibreMac.defaultOutputFolderBookmark"
    }

    /// Launchd/`SMAppService` identities for the per-user agent and its
    /// secure-entry prompter — the two LaunchAgents the host registers on
    /// launch. The plist basenames are the argument to
    /// `SMAppService.agent(plistName:)`; the bundles that carry them are
    /// produced by the packaging task.
    public enum AgentService {
        public static let launchdPlistName = "org.librescrs.agent.plist"
        public static let prompterPlistName = "org.librescrs.prompter.plist"
    }
}

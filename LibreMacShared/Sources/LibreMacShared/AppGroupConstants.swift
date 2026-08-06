// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Constants shared between the host app and the CTK appex. Centralised
/// so a typo in either process surfaces at compile time, not runtime.
public enum AppGroupConstants {
    public static let appGroupId = "group.org.librescrs.LibreMac"
    public static let preferencesSuiteName = "group.org.librescrs.LibreMac.preferences"
    public static let keychainAccessGroup = "group.org.librescrs.LibreMac"

    public enum DefaultsKeys {
        public static let preferredLocale = "org.librescrs.LibreMac.preferredLocale"
        public static let logLevel = "org.librescrs.LibreMac.logLevel"
        /// Where signed files are offered by default. Client-local: the agent
        /// has no say in where this host puts a file it wrote.
        public static let defaultOutputFolder = "org.librescrs.LibreMac.defaultOutputFolder"
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

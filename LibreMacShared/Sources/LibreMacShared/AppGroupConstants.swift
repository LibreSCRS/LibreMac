// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Constants shared between the host app and (in P4) the CTK appex. Centralised
/// so a typo in either process surfaces at compile time, not runtime.
public enum AppGroupConstants {
    public static let appGroupId = "group.org.librescrs.LibreMac"
    public static let preferencesSuiteName = "group.org.librescrs.LibreMac.preferences"
    public static let keychainAccessGroup = "group.org.librescrs.LibreMac"

    public enum DefaultsKeys {
        public static let preferredLocale = "org.librescrs.LibreMac.preferredLocale"
        public static let logLevel = "org.librescrs.LibreMac.logLevel"
    }

    public enum XPCService {
        public static let machServiceName = "org.librescrs.LibreMac.helper"
    }
}

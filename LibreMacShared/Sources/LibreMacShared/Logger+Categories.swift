// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import os

/// # Logging privacy convention (LibreMac)
///
/// Apple's `os.Logger` API tags interpolated values with a privacy level
/// (`public`, `private`, `auto`). LibreMac follows a single convention so
/// log statements stay consistent across files:
///
/// - **`.public`** — values that carry no user-identifying information and
///   that are useful in field diagnostics:
///     - Reader names ("Yubico YubiKey 5C OTP+CCID 0").
///     - Plugin counts, certificate counts, retry counts.
///     - ATR bytes (descriptors of the card family, not the cardholder).
///     - Status enum names ("readerConnected", "ready", "error").
///     - Error message strings produced by LibreMiddleware (the LM API
///       contract guarantees these never contain secret material).
///
/// - **`.private` / `.auto`** — values that may identify a user or device:
///     - Card serial numbers.
///     - Personal data fields (name, document number, etc.).
///     - File paths under user-home or other PII-bearing roots.
///
/// - **Never logged at any level**:
///     - PIN, PUK, CAN, MRZ — even masked / hashed. These never enter a
///       log statement; if a developer ever needs to debug a credential
///       path, the debug build's path goes through a guard that aborts
///       in release configurations. See `feedback_card_data_integrity.md`.
///
/// The convention applies to every Logger.* call across LibreMac and
/// LibreMacShared.
extension Logger {
    /// Subsystem used by every LibreMac log statement. Visible in Console.app
    /// under "org.librescrs.LibreMac" once the host app is running.
    public static let subsystem = "org.librescrs.LibreMac"

    /// Application lifecycle (launch, foreground, terminate).
    public static let app = Logger(subsystem: subsystem, category: "app")
    /// C++ bridge (CardPluginRegistry interactions, FFI).
    public static let bridge = Logger(subsystem: subsystem, category: "bridge")
    /// Card I/O, ATR detection, plugin selection.
    public static let card = Logger(subsystem: subsystem, category: "card")
    /// Signing flow (PIN, sign, post-process).
    public static let signing = Logger(subsystem: subsystem, category: "signing")
    /// Cross-process XPC (P4 onwards; registered now for forward compatibility).
    public static let xpc = Logger(subsystem: subsystem, category: "xpc")
}

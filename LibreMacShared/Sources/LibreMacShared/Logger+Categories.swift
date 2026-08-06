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
///     - Agent-assigned reader/card handles ("reader/0", "card/1") —
///       opaque session-scoped identifiers, not cardholder data.
///     - Certificate counts and certificate ids (the SHA-256 hex of the
///       certificate DER — the agent's own objectID scheme).
///     - Status/state enum case names, LaunchAgent service labels (plist
///       basenames), and the token driver class id.
///     - Error descriptions of this project's own error types
///       (`AgentClientError`, `MessageError`, `TokenTransportError`):
///       they render case, tag, and field NAMES only — never frame
///       payload contents — so their `localizedDescription` is equally
///       payload-free.
///
/// - **`.private` / `.auto`** — values that may identify a user or device:
///     - Personal data fields the agent reads from the card (name,
///       document number, photo) — currently never interpolated into any
///       log statement at all.
///     - User-chosen document names and paths (signing inputs/outputs).
///     - Card serial numbers.
///
/// - **Never logged at any level**:
///     - PIN, PUK, CAN, MRZ — even masked / hashed. The host and the token
///       extension never hold these (credential entry happens agent-side,
///       on the protected auth path), so no log statement here can ever
///       receive one — and none may ever interpolate one.
///
/// The convention applies to every Logger.* call across LibreMac and
/// LibreMacShared, and equally to the package-internal mirror logger in
/// LibreMacAgentClient (same subsystem and category strings).
extension Logger {
    /// Subsystem used by every LibreMac log statement. Visible in Console.app
    /// under "org.librescrs.LibreMac" once the host app is running.
    public static let subsystem = "org.librescrs.LibreMac"

    /// Application lifecycle (launch, foreground, terminate).
    public static let app = Logger(subsystem: subsystem, category: "app")
    /// Card presence and credential flows: the agent-reported registry,
    /// certificate reads, credential listings, token identity publication.
    public static let card = Logger(subsystem: subsystem, category: "card")
    /// Signing flow (consent, sign, post-process).
    public static let signing = Logger(subsystem: subsystem, category: "signing")
    /// Agent client: connection lifecycle, registration, socket transport.
    public static let agent = Logger(subsystem: subsystem, category: "agent")
}

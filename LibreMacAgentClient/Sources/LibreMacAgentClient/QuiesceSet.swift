// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

/// The quiesces the agent has announced and not yet ended, one entry per
/// reason. Mirrors the agent's own `QuiesceSet` (LibreAgent
/// `wire/QuiesceReason.h`): a reason is begun by `AgentQuiesced` and ended by
/// `AgentResumed` with the same reason, and the card surface stays quiesced
/// while any reason is active — a lock that outlasts a wake keeps it quiesced
/// until the unlock.
public struct QuiesceSet: Sendable, Equatable {
    private var reasons: [QuiesceReason] = []

    public init() {}

    /// Marks `reason` active. True when it was not active before.
    @discardableResult
    public mutating func begin(_ reason: QuiesceReason) -> Bool {
        guard !reasons.contains(reason) else { return false }
        reasons.append(reason)
        return true
    }

    /// Ends `reason`. True when it was active.
    @discardableResult
    public mutating func end(_ reason: QuiesceReason) -> Bool {
        guard reasons.contains(reason) else { return false }
        reasons.removeAll { $0 == reason }
        return true
    }

    /// Forgets every reason (the agent that announced them is gone).
    public mutating func clear() { reasons.removeAll() }

    public var isEmpty: Bool { reasons.isEmpty }

    /// The earliest still-active reason, for display.
    public var first: QuiesceReason? { reasons.first }
}

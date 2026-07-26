// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Pure, dependency-free capability resolver (`uiStateFor` / `resolveCardState`,
// the Qt-free helpers). Kept in its own file so the state machine is
// unit-testable without a `CardMonitor`, an `AgentClient`, or any
// SwiftUI/AppKit dependency.

import LibreMacAgentClient

/// Coarse UI grouping a surface renders from a card's capability set: the 2×2
/// IdentityData×PKI grouping, plus the pre-auth latch and the
/// present-but-no-usable-surface `error` sentinel.
public enum CardUiState: Sendable, Equatable {
    case noCard
    case none
    case preAuthRequired
    case identityOnly
    case pkiOnly
    case hybrid
    case error
}

/// Map a capability bitfield to its coarse UI grouping — pure 2×2 over
/// {identityData, pki}; everything else (emrtdCrypto, pinManagement) is
/// ancillary and does not, on its own, create a surface.
public func uiStateFor(_ caps: Capabilities) -> CardUiState {
    let identity = caps.contains(.identityData)
    let pki = caps.contains(.pki)
    if identity && pki { return .hybrid }
    if identity { return .identityOnly }
    if pki { return .pkiOnly }
    return .none
}

/// Resolve a card's full UI state, owning the latch logic every surface would
/// otherwise re-implement:
///   - not present                                   -> `.noCard`
///   - present, a pre-read unlock is required AND
///     identity not yet read                         -> `.preAuthRequired`
///   - otherwise the coarse `uiStateFor` grouping, with a usable-capability
///     `.none` promoted to `.error` (a present card the agent exposes no
///     surface for is an error to the user, distinct from "no card at all").
///
/// Wire tolerance: this is the mapping layer `PreReadAuth`'s type doc
/// comment designates for deciding what an unrecognized value MEANS
/// (`ClientCodec.h`'s tolerance table: "the card-property mapping ... treats
/// it the same as the default, None"). `Messages.swift` already carries an
/// unrecognized value through raw as `.unknown(UInt32)` rather than failing
/// the frame; gating the pre-auth latch on a future unlock method this
/// build cannot honor would incorrectly strand the card behind a prompt it
/// can never satisfy, so an unrecognized value is normalized to `.none`
/// here before the latch check.
public func resolveCardState(
    caps: Capabilities, preAuth: PreReadAuth, present: Bool, identityRead: Bool
) -> CardUiState {
    if !present { return .noCard }
    let effectivePreAuth = preAuth.isKnown ? preAuth : .none
    if effectivePreAuth != .none && !identityRead { return .preAuthRequired }
    let grouped = uiStateFor(caps)
    return grouped == .none ? .error : grouped
}

/// The high-level presence the menu-bar UI renders. Derived from the agent's
/// availability flag, the reader/card registry, and any pending
/// `AgentQuiesced` reason — the single value `CardStatusView` and the
/// menu-bar icon switch over.
public enum Presence: Sendable, Equatable {
    /// The agent connection is down (never connected, or lost + backing off).
    case agentUnavailable
    /// Agent up, but no reader is attached.
    case noReader
    /// A reader is attached but holds no card.
    case readerEmpty
    /// A card is present; the payload is its resolved capability grouping.
    case card(CardUiState)
    /// The session is suspended (system sleep / screen lock / user switch /
    /// shutdown). Overrides the card surface so a stale "certificates ready"
    /// UI never survives a lock; cleared on the next registry snapshot.
    case quiesced(QuiesceReason)
}

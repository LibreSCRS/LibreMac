// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Tests for the pure capability resolver (presence + pre-auth → UI state).

import Testing
import LibreMacAgentClient
@testable import LibreMac

@Suite("CardPresence")
struct CardPresenceTests {

    @Test("uiStateFor maps the 2×2 identity×pki grouping")
    func uiStateForGrouping() {
        #expect(uiStateFor([]) == .none)
        #expect(uiStateFor(.pki) == .pkiOnly)
        #expect(uiStateFor(.identityData) == .identityOnly)
        #expect(uiStateFor([.identityData, .pki]) == .hybrid)
        // Ancillary bits alone create no surface.
        #expect(uiStateFor(.emrtdCrypto) == .none)
        #expect(uiStateFor([.emrtdCrypto, .pinManagement]) == .none)
    }

    @Test("resolveCardState honours the not-present and pre-auth latches")
    func resolveLatches() {
        #expect(resolveCardState(caps: .pki, preAuth: .none, present: false, identityRead: false) == .noCard)
        // Pre-auth required and identity not yet read -> the unlock prompt.
        #expect(resolveCardState(caps: .identityData, preAuth: .paceCan, present: true, identityRead: false) == .preAuthRequired)
        // Same card, identity already read -> the latch clears.
        #expect(resolveCardState(caps: .identityData, preAuth: .paceCan, present: true, identityRead: true) == .identityOnly)
    }

    @Test("a present card with no usable capability is an error, not none")
    func presentButUnusableIsError() {
        #expect(resolveCardState(caps: [], preAuth: .none, present: true, identityRead: false) == .error)
        #expect(resolveCardState(caps: .emrtdCrypto, preAuth: .none, present: true, identityRead: false) == .error)
    }

    @Test("a present hybrid card resolves to hybrid")
    func hybridResolves() {
        #expect(resolveCardState(caps: [.identityData, .pki], preAuth: .none, present: true, identityRead: false) == .hybrid)
    }
}

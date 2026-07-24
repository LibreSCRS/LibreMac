// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import LibreMacAgentClient
import Testing

@testable import LibreMac

private func reader(_ handle: String, _ name: String) -> ReaderState {
    ReaderState(handle: handle, name: name, hasCard: true, card: nil)
}

private func card(_ handle: String, reader: String, _ caps: Capabilities) -> CardState {
    CardState(handle: handle, reader: reader, caps: caps, preAuth: .none)
}

@Suite("Reader selection")
struct ReaderSelectionTests {

    // Reader R1 sorts AFTER R2 by NAME ("Beta" > "Alpha"), regardless of handle.
    private let readers = [reader("R1", "Beta"), reader("R2", "Alpha")]

    @Test("sortedCards orders by reader name, independent of input order")
    func deterministicOrder() {
        let c1 = card("C1", reader: "R1", .pki)  // reader name "Beta"
        let c2 = card("C2", reader: "R2", .identityData)  // reader name "Alpha"
        let a = sortedCards([c1, c2], readers: readers)
        let b = sortedCards([c2, c1], readers: readers)
        #expect(a.map(\.handle) == ["C2", "C1"])
        #expect(a == b, "order must not depend on the input array order")
    }

    @Test("resolveActiveCard returns the selected reader's card when present")
    func selectedPresent() {
        let c1 = card("C1", reader: "R1", .pki)
        let c2 = card("C2", reader: "R2", .identityData)
        let active = resolveActiveCard(cards: [c1, c2], readers: readers, selectedReader: "R1")
        #expect(active?.handle == "C1")
    }

    @Test("resolveActiveCard falls back to the deterministic first when the selection has no card")
    func selectedAbsentFallsBack() {
        let c1 = card("C1", reader: "R1", .pki)
        let c2 = card("C2", reader: "R2", .identityData)
        let active = resolveActiveCard(cards: [c1, c2], readers: readers, selectedReader: "R3")
        #expect(active?.handle == "C2", "R2/Alpha sorts first")
    }

    @Test("resolveActiveCard with no selection returns the deterministic first")
    func nilSelection() {
        let c1 = card("C1", reader: "R1", .pki)
        let c2 = card("C2", reader: "R2", .identityData)
        let active = resolveActiveCard(cards: [c1, c2], readers: readers, selectedReader: nil)
        #expect(active?.handle == "C2")
    }

    @Test("heterogeneous mix: selecting an identity-only reader picks that card, not the PKI one")
    func heterogeneousSelection() {
        let r = [reader("R1", "Alpha"), reader("R2", "Beta"), reader("R3", "Gamma")]
        let eid = card("C1", reader: "R1", [.pki, .identityData, .pinManagement])
        let passport = card("C2", reader: "R2", [.identityData, .emrtdCrypto])
        let vehicle = card("C3", reader: "R3", .identityData)
        let active = resolveActiveCard(
            cards: [eid, passport, vehicle], readers: r, selectedReader: "R2")
        #expect(active?.handle == "C2")
        #expect(active?.caps.contains(.pki) == false)
    }

    @Test("a re-carded selection is honoured again")
    func reCardedSelection() {
        // Selected R2, but its card is gone -> fallback to R1.
        let c1 = card("C1", reader: "R1", .pki)
        let fallback = resolveActiveCard(cards: [c1], readers: readers, selectedReader: "R2")
        #expect(fallback?.handle == "C1")
        // A new card lands in R2 -> the selection reactivates.
        let c2b = card("C2b", reader: "R2", .identityData)
        let active = resolveActiveCard(cards: [c1, c2b], readers: readers, selectedReader: "R2")
        #expect(active?.handle == "C2b")
    }

    @Test("empty inputs resolve to nil")
    func emptyInputs() {
        #expect(resolveActiveCard(cards: [], readers: [], selectedReader: nil) == nil)
        #expect(sortedCards([], readers: []).isEmpty)
    }
}

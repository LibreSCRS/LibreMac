// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Pure, dependency-free reader-selection decision logic: the deterministic
// ordering and the capability-neutral active-card resolution the CardMonitor
// wires its flows to. No SwiftUI/agent dependency, so it is unit-tested
// directly. Selection is keyed on the reader HANDLE (the wire-unique identity);
// the reader NAME is used only to order rows for a human-readable picker.

import LibreMacAgentClient

/// Deterministic total order for the picker + fallback. Key = the card's reader
/// NAME when that reader is in `readers` (so a device's contact/contactless
/// rows group together and the list reads in a human order), else the reader
/// HANDLE; tiebreak by card handle. Determinism does not depend on the input
/// array order.
func sortedCards(_ cards: [CardState], readers: [ReaderState]) -> [CardState] {
    let nameByHandle = Dictionary(
        readers.map { ($0.handle, $0.name) }, uniquingKeysWith: { first, _ in first })
    return cards.sorted { lhs, rhs in
        let lKey = nameByHandle[lhs.reader] ?? lhs.reader
        let rKey = nameByHandle[rhs.reader] ?? rhs.reader
        if lKey != rKey { return lKey < rKey }
        return lhs.handle < rhs.handle
    }
}

/// The one card every flow acts on: the selected reader's card if it still
/// holds one, else the deterministic first. Capability-neutral — an
/// identity-only card (passport, vehicle) is a valid active card.
func resolveActiveCard(cards: [CardState], readers: [ReaderState], selectedReader: String?) -> CardState? {
    if let selected = selectedReader, let hit = cards.first(where: { $0.reader == selected }) {
        return hit
    }
    return sortedCards(cards, readers: readers).first
}

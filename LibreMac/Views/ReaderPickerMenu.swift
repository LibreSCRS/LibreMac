// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Inline reader picker for the menu-bar menu. Rendered only for >= 2 present
// cards; a single card collapses to nothing (the status view already names it).
// Selecting a row re-targets every flow to that reader's card. The checkmark
// follows the RESOLVED active card (via the binding's getter), not the raw
// click, so a removed selection re-lands on the deterministic fallback.

import LibreMacAgentClient
import LibreMacShared
import SwiftUI

struct ReaderPickerMenu: View {
    @Environment(CardMonitor.self) var monitor

    var body: some View {
        if monitor.readersWithCards.count >= 2 {
            Picker(loc("libremac_reader_picker_title", "Reader"), selection: readerBinding) {
                ForEach(monitor.readersWithCards, id: \.handle) { card in
                    Text(monitor.readerLabel(for: card.reader)).tag(Optional(card.reader))
                }
            }
            .pickerStyle(.inline)
            Divider()
        }
    }

    private var readerBinding: Binding<String?> {
        Binding(
            get: { monitor.activeCard?.reader },
            set: { newValue in if let handle = newValue { monitor.selectReader(handle) } })
    }

    private func loc(_ key: String, _ fallback: String) -> String {
        LocalizedText(key: key, defaultText: fallback).resolve()
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Renders the current `CardMonitor.Status` as a labelled icon in the menu-bar
// popover. Pure presentation — no I/O, no bridge calls. The view model is
// injected through SwiftUI's `@Environment` so unit / preview hosts can
// swap a fake `CardMonitor` without changing this view.

import LibreMacShared
import SwiftUI

struct CardStatusView: View {
    @Environment(CardMonitor.self) var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch monitor.status {
            case .noReader:
                Label("No reader detected", systemImage: "creditcard")
                    .foregroundStyle(.secondary)
            case .readerConnected:
                Label("Reader connected — insert card", systemImage: "creditcard")
            case .cardPresent(let atr):
                Label("Card present", systemImage: "creditcard.fill")
                Text("ATR: \(atr)").font(.caption).foregroundStyle(.secondary)
            case .readingCertificates:
                Label("Reading certificates…", systemImage: "creditcard.fill")
            case .ready(let n):
                Label(
                    "\(n) certificate\(n == 1 ? "" : "s") ready",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case .error(let err):
                Label(
                    "Error: \(err.localizedDescription)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }
        }
    }
}

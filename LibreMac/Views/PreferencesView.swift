// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import LibreMacShared
import SwiftUI

struct PreferencesView: View {
    var body: some View {
        Form {
            Section(loc("libremac_prefs_section_general", "General")) {
                Text(loc("libremac_prefs_placeholder",
                         "No configurable settings in this release."))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 480, height: 300)
    }

    private func loc(_ key: String, _ fallback: String) -> String {
        LocalizedText(key: key, defaultText: fallback).resolve()
    }
}

#Preview {
    PreferencesView()
}

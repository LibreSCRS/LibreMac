// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import SwiftUI

struct PreferencesView: View {
    var body: some View {
        Form {
            Section("General") {
                Text("Settings are not configurable yet. This is a placeholder.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 480, height: 300)
    }
}

#Preview {
    PreferencesView()
}

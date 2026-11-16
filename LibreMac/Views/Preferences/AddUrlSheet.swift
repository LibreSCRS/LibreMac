// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The two add sheets for the trust pane. Both validate the URL for
// immediacy only: the agent is the authority on what it will accept, and a
// URL this sheet allows can still be refused — that refusal is shown in the
// pane exactly as the agent worded it.

import LibreMacAgentClient
import SwiftUI

/// Accepts exactly what the agent keeps for a timestamp, trusted-list or
/// anchor source: the scheme `https`, written in lower case, then a non-empty
/// authority that does not start with `/`. The agent is still the authority
/// and may refuse more; this only spares the user a refusal after typing.
func isUsableTrustUrl(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("https://") else { return false }
    let authority = trimmed.dropFirst("https://".count)
    return !authority.isEmpty && authority.first != "/"
}

struct AddUrlSheet: View {
    let title: String
    let add: (String) -> Void

    @Environment(AppLocalization.self) private var localization
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("https://", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            if !text.isEmpty && !isUsableTrustUrl(text) {
                Label(
                    localization.loc(
                        "libremac_settings_invalid_url", "Enter a full https address."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(localization.loc("libremac_settings_action_cancel", "Cancel")) { dismiss() }
                Button(localization.loc("libremac_settings_action_add", "Add")) {
                    add(text.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isUsableTrustUrl(text))
            }
        }
        .padding(20)
    }
}

struct AddSourceSheet: View {
    let add: (TslSource) -> Void

    @Environment(AppLocalization.self) private var localization
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isLotl = false
    @State private var eager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localization.loc("libremac_settings_tl_add_title", "Add a trusted list")).font(.headline)
            TextField("https://", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            Toggle(localization.loc("libremac_settings_tl_type", "List of lists"), isOn: $isLotl)
            Toggle(
                localization.loc("libremac_settings_trust_eager", "Fetched up front"), isOn: $eager)
            if !text.isEmpty && !isUsableTrustUrl(text) {
                Label(
                    localization.loc(
                        "libremac_settings_invalid_url", "Enter a full https address."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(localization.loc("libremac_settings_action_cancel", "Cancel")) { dismiss() }
                Button(localization.loc("libremac_settings_action_add", "Add")) {
                    add(
                        TslSource(
                            url: text.trimmingCharacters(in: .whitespaces), isLotl: isLotl,
                            eager: eager))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isUsableTrustUrl(text))
            }
        }
        .padding(20)
    }
}

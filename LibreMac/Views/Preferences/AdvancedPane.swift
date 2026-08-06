// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Paths the agent owns and this window cannot change. Shown because "where
// is it reading plugins from" is the first question when a card is not
// recognised, and answering it here beats reading a configuration file.

import LibreMacAgentClient
import SwiftUI

struct AdvancedPane: View {
    let model: PreferencesModel
    @Environment(AppLocalization.self) private var localization

    var body: some View {
        Form {
            switch model.availability {
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .unavailable:
                Section { AgentUnavailableNotice() }
            case .ready:
                Section {
                    pathRow("libremac_settings_plugin_dir", "Plugins", model.pluginDir)
                    pathRow("lc-settings-cache-dir", "Cache", model.tslCacheDir)
                    pathRow(
                        "libremac_settings_aia_cache_dir", "Certificate cache", model.aiaCacheDir)
                } footer: {
                    Text(
                        loc(
                            "libremac_settings_agent_owned_paths",
                            "These are set in the agent's configuration file and cannot be "
                                + "changed from here.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        // Grouped, not the default column style: the column style sizes its
        // label column to the longest label, so the whole form shifted when
        // the language changed and the labels changed width.
        .formStyle(.grouped)
    }

    /// Selectable rather than plain text: the reason to show a path is to
    /// copy it into a terminal or a bug report.
    @ViewBuilder
    private func pathRow(_ key: String, _ fallback: String, _ value: String) -> some View {
        LabeledContent(loc(key, fallback)) {
            Text(value.isEmpty ? loc("libremac_settings_path_unset", "Not set") : value)
                .textSelection(.enabled)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loc(_ key: String, _ fallback: String) -> String {
        localization.loc(key, fallback)
    }
}

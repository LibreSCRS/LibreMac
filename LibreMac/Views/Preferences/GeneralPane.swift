// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Client-local preferences only. Nothing on this pane goes over the socket:
// the language is this host's own choice, and the default output folder is
// where this host offers to put a file the agent handed back. The agent has
// no say in either.

import AppKit
import LibreMacShared
import SwiftUI

struct GeneralPane: View {
    @Environment(AppLocalization.self) private var localization
    @AppStorage(AppGroupConstants.DefaultsKeys.defaultOutputFolder)
    private var outputFolder = ""

    var body: some View {
        @Bindable var localization = localization
        Form {
            Section {
                // Every tag is spelled `String?` on purpose. A Picker whose
                // selection is `String?` needs tags of exactly that type; a
                // `String` tag compiles cleanly and then shows an empty
                // selection at runtime.
                Picker(
                    localization.loc("lc-settings-language", "Language:"),
                    selection: $localization.locale
                ) {
                    Text(localization.loc("libremac_settings_language_system", "System"))
                        .tag(String?.none)
                    Text("English").tag(String?("en"))
                    Text("Српски").tag(String?("sr"))
                }
            }

            Section {
                LabeledContent(
                    localization.loc("lc-settings-default-output", "Default output folder:")
                ) {
                    HStack(spacing: 8) {
                        TextField(
                            "", text: $outputFolder,
                            prompt: Text(
                                localization.loc(
                                    "lc-settings-output-placeholder", "Same as input file"))
                        )
                        .labelsHidden()
                        Button(localization.loc("libremac_settings_browse", "Browse…")) {
                            pickFolder()
                        }
                    }
                }
            } footer: {
                Text(
                    localization.loc(
                        "libremac_settings_output_footer",
                        "Leave empty to save each signed file beside the one it was made from.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        // Grouped, not the default column style: the column style sizes its
        // label column to the longest label, so the whole form shifted when
        // the language changed and the labels changed width.
        .formStyle(.grouped)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url.path
        }
    }
}

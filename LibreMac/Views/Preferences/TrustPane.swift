// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// What this computer trusts: the timestamping authorities it will use and the
// trusted lists it accepts signatures against. Every change here is gated by
// the agent on the device owner's own authentication, so each one asks — this
// pane is deliberately not a place where edits accumulate silently.

import LibreMacAgentClient
import SwiftUI

struct TrustPane: View {
    @Bindable var model: PreferencesModel
    @Environment(AppLocalization.self) private var localization

    @State private var addingTsa = false
    @State private var addingSource = false
    @State private var clearing: SettableConfigKey?

    var body: some View {
        Form {
            switch model.availability {
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .unavailable:
                Section { AgentUnavailableNotice() }
            case .ready:
                tsaSection
                sourcesSection
            }
        }
        // Grouped, not the default column style: the column style sizes its
        // label column to the longest label, so the whole form shifted when
        // the language changed and the labels changed width.
        .formStyle(.grouped)
        .sheet(isPresented: $addingTsa) {
            // Its own copy, not the trusted-list sheet's: these two add
            // different things, and one shared string said "add a trusted
            // list" over the timestamping section.
            AddUrlSheet(title: loc("libremac_settings_trust_add_tsa_title", "Add a timestamping authority")) { url in
                Task { await model.save(.tsaUrls, urlsValue(model.tsaUrls + [url])) }
            }
        }
        .sheet(isPresented: $addingSource) {
            AddSourceSheet { source in
                Task { await model.save(.tslSources, sourcesValue(model.tslSources + [source])) }
            }
        }
        // Two questions, and they are not the same question: this one asks
        // whether to discard what is there, and the agent's own prompt that
        // follows asks whether the person at the keyboard may change trust at
        // all. Neither answers the other.
        .confirmationDialog(
            loc("libremac_settings_trust_clear_title", "Remove every entry?"),
            isPresented: clearingBinding, presenting: clearing
        ) { key in
            Button(loc("libremac_settings_trust_clear_confirm", "Remove all"), role: .destructive) {
                Task { await model.reset(key) }
            }
            Button(loc("libremac_settings_action_cancel", "Cancel"), role: .cancel) {}
        } message: { key in
            Text(clearingMessage(for: key))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var tsaSection: some View {
        Section(loc("lc-settings-tsa-servers", "Timestamping authorities")) {
            if model.tsaUrls.isEmpty {
                Text(loc("libremac_settings_trust_no_tsa", "No authority configured — signatures are not timestamped."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.tsaUrls, id: \.self) { url in
                row(url) {
                    Task { await model.save(.tsaUrls, urlsValue(model.tsaUrls.filter { $0 != url })) }
                }
            }
            rowNote(.tsaUrls)
            HStack {
                Button(loc("libremac_settings_trust_add_tsa", "Add a server…")) { addingTsa = true }
                Spacer()
                if !model.tsaUrls.isEmpty {
                    Button(loc("libremac_settings_trust_clear", "Remove all"), role: .destructive) {
                        clearing = .tsaUrls
                    }
                }
            }
            if !model.lastTsaUrl.isEmpty {
                LabeledContent(loc("libremac_settings_last_tsa", "Last used")) {
                    Text(model.lastTsaUrl)
                        .textSelection(.enabled)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        Section(loc("lc-settings-tl-servers", "Trusted lists")) {
            if model.tslSources.isEmpty {
                Text(
                    loc(
                        "libremac_settings_trust_no_lists",
                        "No trusted list configured — signatures cannot be validated against one.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(model.tslSources, id: \.url) { source in
                row(source.url, subtitle: flagLabel(source)) {
                    Task {
                        await model.save(
                            .tslSources, sourcesValue(model.tslSources.filter { $0.url != source.url }))
                    }
                }
            }
            rowNote(.tslSources)
            HStack {
                Button(loc("lc-settings-tl-add-item", "Add…")) { addingSource = true }
                Spacer()
                if !model.tslSources.isEmpty {
                    Button(loc("libremac_settings_trust_clear", "Remove all"), role: .destructive) {
                        clearing = .tslSources
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func row(_ url: String, subtitle: String? = nil, remove: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(url)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(loc("libremac_settings_trust_remove", "Remove"))
        }
    }

    @ViewBuilder
    private func rowNote(_ key: SettableConfigKey) -> some View {
        if let message = model.rowError[key] {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func flagLabel(_ source: TslSource) -> String {
        var parts: [String] = []
        if source.isLotl { parts.append(loc("lc-settings-tl-type", "List of lists")) }
        if source.eager { parts.append(loc("libremac_settings_trust_eager", "Fetched up front")) }
        return parts.joined(separator: " · ")
    }

    private func clearingMessage(for key: SettableConfigKey) -> String {
        let count = key == .tsaUrls ? model.tsaUrls.count : model.tslSources.count
        return localization.loc(
            "libremac_settings_trust_clear_msg",
            "This removes all {count} entries. You will be asked to confirm the change itself as well.",
            placeholders: ["count": String(count)])
    }

    /// `confirmationDialog` wants a Bool it can clear; the key it is about is
    /// what the pane actually tracks.
    private var clearingBinding: Binding<Bool> {
        Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })
    }

    private func urlsValue(_ urls: [String]) -> CBORValue {
        .array(urls.map { .text($0) })
    }

    private func sourcesValue(_ sources: [TslSource]) -> CBORValue {
        .array(sources.map(\.cbor))
    }

    private func loc(_ key: String, _ fallback: String) -> String {
        localization.loc(key, fallback)
    }
}

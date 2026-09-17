// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// What this computer trusts: the timestamping authorities it will use and the
// trusted lists it accepts signatures against. Every change here is gated by
// the agent on the device owner's own authentication, so each one asks — this
// pane is deliberately not a place where edits accumulate silently.

import Foundation
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
                anchorsSection
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

    /// What the agent holds to check a passport's issuing country against.
    /// Read-only: nothing here is installed from this window, and the agent
    /// would refuse a write to it in any case. Shown so that a host which has
    /// never seen an import can still say what is installed, rather than
    /// leaving a person to assume.
    @ViewBuilder
    private var anchorsSection: some View {
        Section(loc("libremac_settings_trust_anchors", "Country-signing anchors")) {
            switch model.cscaAnchors {
            case .held(let state):
                held(state)
            case .nothingImported:
                Text(
                    loc(
                        "libremac_settings_trust_no_anchors",
                        "No country-signing anchors installed — passports cannot be checked against the country that issued them.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            case .unreadable:
                // NOT the sentence above. "Nothing is installed" is a claim
                // about what this computer trusts, and a value that failed to
                // decode is no evidence for it.
                Text(
                    loc(
                        "libremac_settings_trust_anchors_unreadable",
                        "The agent reported anchor state this app could not read.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func held(_ state: CscaAnchorState) -> some View {
        LabeledContent(loc("libremac_settings_trust_anchors_held", "Anchors held")) {
            Text(number(state.anchors)).foregroundStyle(.secondary)
        }
        LabeledContent(loc("libremac_settings_trust_anchor_issuers", "Issuing countries")) {
            Text(number(state.issuers)).foregroundStyle(.secondary)
        }
        if let acceptedAt = state.acceptedAt {
            LabeledContent(loc("libremac_settings_trust_anchors_accepted", "Accepted")) {
                Text(stamp(acceptedAt)).foregroundStyle(.secondary)
            }
        }
        // When the list says it was signed, as distinct from when this
        // computer took it. Absent whenever the publisher left it out, which
        // is also what the rollback line below reports.
        if let signedAt = state.signedAt {
            LabeledContent(loc("libremac_settings_trust_anchors_signed", "Signed")) {
                Text(stamp(signedAt)).foregroundStyle(.secondary)
            }
        }
        // An import that took in several publishers names none of them, but
        // whether their identity was ESTABLISHED is a fact about all of them
        // and survives on its own — so the two are shown independently rather
        // than the second hanging off the first.
        if state.signer != nil || state.signerPinned != nil {
            LabeledContent(loc("libremac_settings_trust_anchor_signer", "Publisher")) {
                VStack(alignment: .trailing, spacing: 2) {
                    if let signer = state.signer {
                        Text(signer)
                            .textSelection(.enabled)
                            .font(.system(.caption, design: .monospaced))
                    }
                    if let pinned = state.signerPinned {
                        Text(signerLabel(pinned)).font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        // Its FALSE is the value worth saying out loud: at least one accepted
        // list carried no signing time, so "is this older than what I hold"
        // cannot be answered at all. Staying silent would leave a person
        // unable to tell "this is safe" from "this cannot be checked" — and a
        // field that never ARRIVED is not that false, so nil says nothing.
        if state.replayRefusalActive == false {
            Label(
                loc("libremac_settings_trust_anchors_no_replay_refusal",
                    "Not every accepted list carried a signing time, so a later import cannot be refused for rolling the anchors back."),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
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

    /// Whether the import ESTABLISHED the publisher's identity or merely
    /// observed it — a pinned publisher against a trust-on-first-import.
    private func signerLabel(_ pinned: Bool) -> String {
        pinned
            ? loc("libremac_settings_trust_anchor_signer_pinned", "Identity established")
            : loc("libremac_settings_trust_anchor_signer_unpinned", "Identity seen but not established")
    }

    /// A count in the window's chosen language, so its grouping separator
    /// matches the date beside it rather than following the system's locale.
    private func number(_ value: UInt64) -> String {
        guard let chosen = localization.locale else { return value.formatted(.number) }
        return value.formatted(.number.locale(Locale(identifier: chosen)))
    }

    /// Epoch seconds as a date a person reads. Rendered in the language the
    /// window is showing rather than the system's, so a date does not stay
    /// English beside Serbian labels; reading `localization.locale` here is
    /// also what redraws this row when the language changes.
    private func stamp(_ seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        if let chosen = localization.locale {
            style = style.locale(Locale(identifier: chosen))
        }
        return date.formatted(style)
    }

    private func loc(_ key: String, _ fallback: String) -> String {
        localization.loc(key, fallback)
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Agent-backed rows. Every value here belongs to the agent: this pane reads
// a snapshot, writes one key at a time, and shows what the agent said when
// it refused. It never decides a value itself.

import LibreMacAgentClient
import SwiftUI

struct SigningPane: View {
    @Bindable var model: PreferencesModel
    @Environment(AppLocalization.self) private var localization

    /// Which text row has the keyboard. A focused row is marked as being
    /// edited so a change arriving from elsewhere cannot rewrite it midway.
    @FocusState private var focused: SettableConfigKey?

    var body: some View {
        Form {
            switch model.availability {
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .unavailable:
                Section { AgentUnavailableNotice() }
            case .ready:
                Section {
                    levelRow
                    textRow(
                        .defaultReason, "libremac_settings_default_reason", "Reason",
                        text: $model.defaultReason)
                    textRow(
                        .defaultLocation, "libremac_settings_default_location", "Location",
                        text: $model.defaultLocation)
                } footer: {
                    Text(
                        loc(
                            "libremac_settings_signing_footer",
                            "Used for every signature unless a request asks for something else.")
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

    // MARK: - Rows

    @ViewBuilder
    private var levelRow: some View {
        LabeledContent(loc("lc-settings-default-level", "Level")) {
            HStack(spacing: 8) {
                Picker("", selection: levelSelection) {
                    ForEach(Self.levelOptions(), id: \.self) { level in
                        Text(level.rawValue.uppercased()).tag(level.rawValue)
                    }
                }
                .labelsHidden()
                restoreButton(.defaultLevel)
            }
        }
        rowNote(.defaultLevel)
        if let advisory = Self.advisory(
            level: model.defaultLevel, tsaConfigured: !model.tsaUrls.isEmpty)
        {
            Text(advisory)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Writing on selection rather than on commit: a popup has no commit.
    /// The row is deliberately NOT set here — `save` shows the new value and
    /// owns putting the old one back if the agent refuses it.
    private var levelSelection: Binding<String> {
        Binding(
            get: { model.defaultLevel },
            set: { chosen in Task { await model.save(.defaultLevel, .text(chosen)) } })
    }

    @ViewBuilder
    private func textRow(
        _ key: SettableConfigKey, _ stringKey: String, _ fallback: String,
        text: Binding<String>
    ) -> some View {
        LabeledContent(loc(stringKey, fallback)) {
            HStack(spacing: 8) {
                TextField("", text: text)
                    .labelsHidden()
                    .focused($focused, equals: key)
                    // Committing on blur as well as on return: a field that
                    // only wrote on return loses whatever was typed when the
                    // user clicks another tab, which is the ordinary way to
                    // leave.
                    .onChange(of: focused) { previous, current in
                        if current == key {
                            model.beginEditing(key)
                        } else if previous == key {
                            Task { await model.endEditing(key) }
                        }
                    }
                    .onSubmit { Task { await model.commitIfChanged(key) } }
                    // Closing the window, or switching to another tab, tears
                    // the field down without ever moving focus — so without
                    // this a change typed and then dismissed is silently
                    // dropped. Committing twice is safe: the second finds
                    // nothing changed.
                    .onDisappear { Task { await model.endEditing(key) } }
                restoreButton(key)
            }
        }
        rowNote(key)
    }

    /// An icon rather than a third "Restore default" button stacked down the
    /// pane: the rows are what this window is about, and repeating the same
    /// wide button beside each one buries them.
    @ViewBuilder
    private func restoreButton(_ key: SettableConfigKey) -> some View {
        // These keys hold a scalar, so restoring one puts back a string and
        // needs no confirmation. The list-valued keys are deliberately not
        // offered here: resetting one means discarding every entry the user
        // added, which has to ask first.
        Button {
            Task { await model.reset(key) }
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
        .help(loc("libremac_settings_restore_default", "Restore default"))
    }

    @ViewBuilder
    private func rowNote(_ key: SettableConfigKey) -> some View {
        if let message = model.rowError[key] {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Pure helpers

    /// `auto` is a request-only deferral sentinel: stored as the default it
    /// would resolve against itself.
    static func levelOptions() -> [SignatureLevel] {
        SignatureLevel.allCases.filter { $0 != .auto }
    }

    /// The stored default is not always the effective one: the agent raises a
    /// baseline level once a timestamping authority is configured, and it
    /// accepts a long-term level with no authority at all — which fails later,
    /// at signing time, far from here. This states both situations; it never
    /// re-derives the level, because that rule lives in the signing consumer.
    ///
    /// A level that was never read, or one this build has no name for, gets
    /// nothing: both advisories are claims about the agent's configuration,
    /// and there is no claim to make without having read it.
    @MainActor
    static func advisory(level: String, tsaConfigured: Bool) -> String? {
        guard let known = SignatureLevel(rawValue: level), known != .auto else { return nil }
        if tsaConfigured && known == .bB {
            return AppLocalization.shared.loc(
                "libremac_settings_advisory_timestamping_applies",
                "A timestamping authority is configured, so signatures are timestamped "
                    + "even though this level does not require it.")
        }
        if !tsaConfigured && known != .bB {
            return AppLocalization.shared.loc(
                "libremac_settings_advisory_no_tsa",
                "No timestamping authority is configured, so this level cannot be produced. "
                    + "Add one in the agent's configuration file.")
        }
        return nil
    }

    private func loc(_ key: String, _ fallback: String) -> String {
        localization.loc(key, fallback)
    }
}

/// Shown by every pane whose values belong to the agent, so "the agent is not
/// running" reads the same wherever it is met.
struct AgentUnavailableNotice: View {
    @Environment(AppLocalization.self) private var localization

    var body: some View {
        ContentUnavailableView {
            Label(
                localization.loc(
                    "libremac_settings_agent_unavailable_title", "Signing agent not reachable"),
                systemImage: "bolt.horizontal.circle")
        } description: {
            Text(
                localization.loc(
                    "libremac_settings_agent_unavailable",
                    "These settings belong to the signing agent, which is not reachable."))
        }
    }
}

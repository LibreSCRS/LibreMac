// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The sign window: two typed paths, each with Browse… as a convenience, plus
// pure presentation of the `SigningCoordinator` state machine. The paths are
// typed first because the system file panel service crashes on this OS; a
// panel that fails simply leaves the fields as they were. The PIN never
// enters this process: while the operation waits on the user, this view shows
// only "confirm in the card dialog" — the secure prompt is the agent's, over
// the protected authentication path.

import AppKit
import SwiftUI

struct SignView: View {
    @Environment(CardMonitor.self) var monitor
    @Environment(AppLocalization.self) private var localization
    @Bindable var coordinator: SigningCoordinator

    @State private var inputPath = ""
    @State private var destinationPath = ""
    /// The destination this view last filled in itself. A destination the
    /// user typed or picked differs from it and is never overwritten.
    @State private var proposedPath = ""
    @State private var fellBackToDownloads = false
    /// The activation policy to put back when this window closes; nil while it
    /// is not open.
    @State private var previousPolicy: NSApplication.ActivationPolicy?

    var body: some View {
        Form {
            Section {
                LabeledContent(loc("libremac_sign_input_label", "File to sign:")) {
                    HStack(spacing: 8) {
                        TextField("", text: $inputPath)
                            .labelsHidden()
                        Button(loc("libremac_settings_browse", "Browse…")) { pickInputFile() }
                    }
                }
                LabeledContent(loc("libremac_sign_output_label", "Save signed file as:")) {
                    HStack(spacing: 8) {
                        TextField("", text: $destinationPath)
                            .labelsHidden()
                        Button(loc("libremac_settings_browse", "Browse…")) { pickDestination() }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc(
                        "libremac_sign_typed_paths_hint",
                        "Typed paths work inside Downloads and the folders you have chosen; use Browse… for others."))
                    if fellBackToDownloads {
                        Text(loc(
                            "libremac_sign_dest_fallback_downloads",
                            "The default output folder could not be used, so the signed file is offered in Downloads."))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                stageContent
            }
        }
        // Grouped, not the default column style: the column style sizes its
        // label column to the longest label, so the form shifts sideways when
        // the language changes.
        .formStyle(.grouped)
        .frame(width: 520)
        // Proposed after a pause in typing, not per keystroke: the proposal
        // probes the output folder by creating and removing a file in it.
        // The Downloads note belongs to the proposal; a destination the user
        // chose instead makes it untrue.
        .onChange(of: destinationPath) {
            if destinationPath != proposedPath { fellBackToDownloads = false }
            withdrawReplaceQuestion()
        }
        .onChange(of: inputPath) { withdrawReplaceQuestion() }
        .task(id: inputPath) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            proposeDestination()
        }
        // An accessory app is never the active application, so without this
        // the window appears behind whatever was frontmost.
        .onAppear { previousPolicy = AppActivation.begin() }
        .onDisappear {
            if let previousPolicy {
                AppActivation.end(restoring: previousPolicy)
            }
            previousPolicy = nil
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch coordinator.stage {
        case .idle:
            if !monitor.canSign {
                Text(loc(
                    "libremac_sign_no_card",
                    "Insert a card with a signing certificate to sign."))
                    .foregroundStyle(.secondary)
            }
            Button(loc("libremac_sign_action", "Sign")) { startSign() }
                .keyboardShortcut(.defaultAction)
                .disabled(!monitor.canSign || inputPath.isEmpty || destinationPath.isEmpty)
        case .preparing:
            ProgressView(loc("libremac_sign_preparing", "Preparing…"))
        case .awaitingConsent:
            Label(
                loc("libremac_sign_confirm", "Confirm the signature in the card dialog…"),
                systemImage: "hand.tap.fill"
            )
            .foregroundStyle(.orange)
        case .working:
            ProgressView(loc("libremac_sign_working", "Signing…"))
        case let .done(destination, meta):
            Label(doneSummary(destination), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text(levelText("libremac_sign_done_level",
                            "Signed at {level}.", meta.level.uppercased()))
            if !meta.chainComplete {
                Text(loc("libremac_sign_chain_incomplete",
                         "The validation chain could not be completed."))
            }
            Button(loc("libremac_sign_another", "Sign another file")) {
                coordinator.reset()
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Button(loc("libremac_sign_retry", "Try again")) {
                coordinator.reset()
            }
        case let .confirmReplace(destination, signatureDiscarded):
            // Inline, not a system sheet: the panel service is what crashes.
            Label(
                signatureDiscarded
                    ? localization.loc(
                        "libremac_sign_replace_after_discard",
                        "{name} appeared while signing, so the signature was not saved. Replace it? You will be asked for the card again.",
                        placeholders: ["name": destination.lastPathComponent])
                    : localization.loc(
                        "libremac_sign_replace_prompt", "{name} already exists. Replace it?",
                        placeholders: ["name": destination.lastPathComponent]),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            HStack {
                Button(loc("libremac_settings_action_cancel", "Cancel")) {
                    coordinator.reset()
                }
                Button(loc("libremac_sign_replace", "Replace"), role: .destructive) {
                    startSign(replacing: destination)
                }
                .disabled(!monitor.canSign)
            }
        }
    }

    // MARK: - Actions

    private func startSign(replacing confirmed: URL? = nil) {
        guard monitor.canSign,
              let card = monitor.signingCard?.handle,
              let certId = monitor.signingCertId
        else { return }
        let input = inputPath
        let destination = destinationPath
        Task { @MainActor in
            await coordinator.sign(
                card: card, certId: certId, inputPath: input, destinationPath: destination,
                replacing: confirmed)
        }
    }

    /// A replace question is about the paths it was asked for; once either
    /// changes it is withdrawn. (The coordinator also honours a confirmation
    /// only for the file it named.)
    private func withdrawReplaceQuestion() {
        if case .confirmReplace = coordinator.stage { coordinator.reset() }
    }

    /// Fills the destination from the input, unless the user has set one.
    private func proposeDestination() {
        guard let input = coordinator.resolveInput(path: inputPath),
              !input.hasDirectoryPath
        else { return }
        guard destinationPath.isEmpty || destinationPath == proposedPath else { return }
        let proposal = coordinator.proposedDestination(forInput: input)
        proposedPath = proposal.url.path
        destinationPath = proposal.url.path
        fellBackToDownloads = proposal.fellBackToDownloads
    }

    // The panels are a convenience. One that crashes or is cancelled returns
    // something other than `.OK`, and the typed fields stay as they were.

    private func pickInputFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = loc("libremac_sign_pick_input", "Choose file to sign")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inputPath = url.path
    }

    private func pickDestination() {
        let panel = NSSavePanel()
        panel.prompt = loc("libremac_sign_pick_output", "Save signed file")
        if let current = coordinator.resolveDestination(path: destinationPath) {
            panel.directoryURL = current.deletingLastPathComponent()
            panel.nameFieldStringValue = current.lastPathComponent
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationPath = url.path
    }

    private func doneSummary(_ destination: URL) -> String {
        localization.loc(
            "libremac_sign_done", "Signed — saved to {name}",
            placeholders: ["name": destination.lastPathComponent])
    }

    /// The `{level}`-substituted sign-outcome sentence. Named-brace
    /// placeholder through `LocalizedText`, same shape as
    /// `CredentialsView.attributed` — never `%@` with
    /// `replacingOccurrences`: `CatalogCompletenessTests` guards named
    /// placeholders across both locales, so a positional token would bypass
    /// that gate. Single-purpose, like its `CredentialsView` siblings
    /// (`countText`, `rangeText`): the `{level}` key is this call's whole
    /// job, not a general substitution facility.
    private func levelText(_ key: String, _ fallback: String, _ level: String) -> String {
        localization.loc(key, fallback, placeholders: ["level": level])
    }

    private func loc(_ key: String, _ fallback: String) -> String {
        localization.loc(key, fallback)
    }
}

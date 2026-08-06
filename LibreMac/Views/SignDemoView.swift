// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Pure presentation for the `SigningCoordinator` state machine plus the
// file-picking chrome. The PIN never enters this process: while the
// operation waits on the user, this view shows only "confirm in the card
// dialog" — the secure prompt is the agent's, over the protected
// authentication path.

import AppKit
import SwiftUI

struct SignDemoView: View {
    @Environment(CardMonitor.self) var monitor
    @Environment(AppLocalization.self) private var localization
    @Bindable var coordinator: SigningCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("libremac_sign_title", "Sign"))
                .font(.headline)

            switch coordinator.stage {
            case .idle:
                Button(loc("libremac_sign_button", "Sign a file…")) {
                    startSign()
                }
                .disabled(!monitor.canSign)
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
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: - Actions

    private func startSign() {
        guard monitor.canSign,
              let card = monitor.signingCard?.handle,
              let certId = monitor.signingCertId
        else { return }
        Task { @MainActor in
            // Promoted ONCE around both panels, not per panel: flapping back
            // to `.accessory` between the input and the destination panel runs
            // the transition twice, and restoring it also hides any window the
            // app already had open.
            let previousPolicy = AppActivation.begin()
            defer { AppActivation.end(restoring: previousPolicy) }

            // The menu bar menu must fully dismiss before a modal file panel
            // runs; presenting it during menu teardown makes the panel drop
            // the selection and return cancel. Yield a run-loop turn first.
            try? await Task.sleep(for: .milliseconds(200))
            guard let input = pickInputFile(),
                  let destination = pickDestination(for: input)
            else { return }
            await coordinator.sign(
                card: card, certId: certId, inputURL: input, destinationURL: destination)
        }
    }

    private func pickInputFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = loc("libremac_sign_pick_input", "Choose file to sign")
        return runPanel(panel) ? panel.url : nil
    }

    private func pickDestination(for input: URL) -> URL? {
        let panel = NSSavePanel()
        panel.prompt = loc("libremac_sign_pick_output", "Save signed file")
        panel.nameFieldStringValue = input.deletingPathExtension().lastPathComponent + ".p7s"
        return runPanel(panel) ? panel.url : nil
    }

    /// Runs the panel. The caller promotes the app to `.regular` around the
    /// whole pick sequence — see `startSign()`.
    private func runPanel(_ panel: NSSavePanel) -> Bool {
        panel.runModal() == .OK
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

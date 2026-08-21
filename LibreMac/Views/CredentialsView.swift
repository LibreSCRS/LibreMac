// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The credentials window: a flat dashboard of every present card's
// credential records. Pure presentation over `CredentialsViewModel` — the
// listing/mutation flow and the section lifetime live there; this view only
// initiates listings for the cards `CardMonitor` reports as
// PIN-management-capable and renders what the view model publishes. NO
// secret ever passes through this process: every mutation (change,
// unblock, activate, activate-key) names a record handle and the agent
// collects the PINs/PUKs in its own secure dialog.

import LibreMacAgentClient
import SwiftUI

struct CredentialsView: View {
    @Environment(CardMonitor.self) var monitor
    let viewModel: CredentialsViewModel

    /// Presentation-only in-flight latch so a double-click cannot start two
    /// mutations; the view model itself is request-at-a-time by usage.
    @State private var busy = false

    /// The credential an unblock confirm sheet is open for (card, pinId), or nil.
    @State private var unblockTarget: UnblockTarget?

    private struct UnblockTarget: Identifiable {
        let card: String
        let pinId: String
        var id: String { "\(card)\u{0000}\(pinId)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(viewModel.cards, id: \.card) { section in
                    sectionView(section)
                }
                statusArea
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 280)
        .task(id: manageableCardHandles) {
            // On appear and whenever the set of PIN-management-capable cards
            // changes, (re)list each one. Removals need no work here — the
            // view model drops vanished sections from its own registry tap.
            for handle in manageableCardHandles {
                await viewModel.refresh(card: handle)
            }
        }
        .sheet(item: $unblockTarget) { target in
            unblockConfirm(target)
        }
    }

    /// The cards whose credentials this window manages, in a stable order —
    /// `CardMonitor.cards` is registry-dictionary-ordered, so sort to keep
    /// the `.task(id:)` key from churning on unrelated snapshots.
    private var manageableCardHandles: [String] {
        monitor.cards
            .filter { $0.caps.contains(.pinManagement) }
            .map(\.handle)
            .sorted()
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: CredentialsCardSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sectionTitle(for: section.card))
                .font(.headline)
            ForEach(section.records, id: \.id) { record in
                recordRow(card: section.card, record: record)
            }
        }
    }

    /// A section is titled with its reader's display name (agent-provided
    /// data, not copy); the raw card handle is the last-resort fallback.
    private func sectionTitle(for card: String) -> String {
        guard let cardState = monitor.cards.first(where: { $0.handle == card }),
              let reader = monitor.readers.first(where: { $0.handle == cardState.reader })
        else { return card }
        return reader.name
    }

    // MARK: - Record rows

    private func recordRow(card: String, record: CredentialRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.label)
                        .fontWeight(.medium)
                    Text(Self.kindTitle(record.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Self.stateTitle(record.state))
                    .font(.caption)
                    .foregroundStyle(Self.stateTint(record.state))
                if let retries = record.retriesLeft {
                    if let retriesMax = record.retriesMax {
                        Text(Self.rangeText(
                            "libremac_credentials_retries_max", "Attempts: {count} of {max}",
                            retries, retriesMax))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Self.countText(
                            "libremac_credentials_retries_left", "Attempts: {count}", retries))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let uses = record.usesLeft {
                    if let usesMax = record.usesMax {
                        Text(Self.rangeText(
                            "libremac_credentials_uses_max", "Uses: {count} of {max}",
                            uses, usesMax))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Self.countText(
                            "libremac_credentials_uses_left", "Uses: {count}", uses))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // Guidance rides the record as an agent-authored
                // key/fallback pair (the client owns the translations; the
                // catalogs carry the agent's literal keys) — render each
                // line whenever the record advertises it.
                if let key = record.blockedGuidanceKey {
                    guidanceLine(key: key, fallback: record.blockedGuidanceFallback)
                }
                if let key = record.keyActivationGuidanceKey {
                    guidanceLine(key: key, fallback: record.keyActivationGuidanceFallback)
                }
            }
            Spacer(minLength: 12)
            actionButtons(card: card, record: record)
        }
    }

    private func guidanceLine(key: String, fallback: String?) -> some View {
        Text(Self.loc(key, fallback ?? ""))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    /// One button per advertised affordance, strictly from
    /// `viewModel.actions(for:)` (which derives them from the record's
    /// booleans). All four affordances are live: `.change` and the two
    /// activate flows dispatch straight to the view model, while `.unblock`
    /// first raises its confirm sheet — each drives a real view-model
    /// operation.
    @ViewBuilder
    private func actionButtons(card: String, record: CredentialRecord) -> some View {
        let actions = viewModel.actions(for: record)
        HStack(spacing: 8) {
            if actions.contains(.change) {
                Button(Self.loc("libremac_credentials_action_change", "Change…")) {
                    change(card: card, pinId: record.id)
                }
                .disabled(busy)
            }
            if actions.contains(.unblock) {
                Button(Self.loc("libremac_credentials_action_unblock", "Unblock…")) {
                    unblockTarget = UnblockTarget(card: card, pinId: record.id)
                }
                .disabled(busy)
            }
            if actions.contains(.activatePin) {
                Button(Self.loc("libremac_credentials_action_activate_pin", "Activate…")) {
                    run { await viewModel.activate(card: card, pinId: record.id) }
                }
                .disabled(busy)
            }
            if actions.contains(.activateKey) {
                Button(Self.loc(
                    "libremac_credentials_action_activate_key", "Activate Signing Key…")) {
                    run { await viewModel.activateKey(card: card) }
                }
                .disabled(busy)
            }
        }
    }

    private func change(card: String, pinId: String) {
        run { await viewModel.change(card: card, pinId: pinId) }
    }

    /// Runs one view-model mutation behind the presentation-only `busy` latch
    /// so a double-click cannot start two.
    private func run(_ mutation: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await mutation()
            busy = false
        }
    }

    @ViewBuilder
    private func unblockConfirm(_ target: UnblockTarget) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Self.loc("libremac_credentials_unblock_title", "Unblock PIN"))
                .font(.headline)
            if let budget = budgetLine(forCard: target.card) {
                Text(budget)
            }
            Text(Self.loc(
                "libremac_credentials_unblock_prompt_notice",
                "You will be asked for the PUK in a secure prompt."))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(Self.loc("libremac_credentials_action_cancel", "Cancel")) {
                    unblockTarget = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(Self.loc("libremac_credentials_unblock_continue", "Continue")) {
                    let card = target.card
                    let pinId = target.pinId
                    unblockTarget = nil
                    run { await viewModel.unblock(card: card, pinId: pinId) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    /// The PUK budget line for the unblock sheet, or nil when the card has no
    /// PUK usage to show.
    private func budgetLine(forCard card: String) -> String? {
        guard let budget = viewModel.unblockBudget(forCard: card) else { return nil }
        if let max = budget.usesMax {
            return Self.rangeText(
                "libremac_credentials_unblock_budget", "PUK: {count} of {max} unblocks left.",
                budget.usesLeft, max)
        }
        return Self.countText(
            "libremac_credentials_unblock_budget_nomax", "PUK: {count} unblocks left.",
            budget.usesLeft)
    }

    // MARK: - Outcome / error status

    /// The most recent request's result line: an entry error renders via the
    /// `ErrorCopy` sync-error table; otherwise the last mutation outcome
    /// renders via its `libremac_credentials_outcome_<token>` copy.
    @ViewBuilder
    private var statusArea: some View {
        if let error = viewModel.entryError {
            Label(
                AppLocalization.shared.resolve(ErrorCopy.localizedText(for: error)),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.red)
        } else if let result = viewModel.lastOutcome,
                  case let text = Self.outcomeText(result, presented: viewModel.presentedKind),
                  !text.isEmpty {
            Label(text, systemImage: Self.outcomeIcon(result.outcome))
                .font(.callout)
                .foregroundStyle(Self.outcomeTint(result.outcome))
        }
    }

    // MARK: - Localized copy tables

    private static func kindTitle(_ kind: CredentialKind) -> String {
        switch kind {
        case .user:
            return loc("libremac_credentials_kind_user", "User PIN")
        case .sign:
            return loc("libremac_credentials_kind_sign", "Signing PIN")
        case .puk:
            return loc("libremac_credentials_kind_puk", "PUK")
        case .can:
            return loc("libremac_credentials_kind_can", "CAN")
        case .unknown:
            return loc("libremac_credentials_kind_unknown", "Credential")
        }
    }

    private static func stateTitle(_ state: CredentialState) -> String {
        switch state {
        case .unknown:
            return loc("libremac_credentials_state_unknown", "Unknown")
        case .transport:
            return loc("libremac_credentials_state_transport", "Transport — activation needed")
        case .operational:
            return loc("libremac_credentials_state_operational", "Operational")
        case .needsChange:
            return loc("libremac_credentials_state_needs_change", "Change required")
        case .blocked:
            return loc("libremac_credentials_state_blocked", "Blocked")
        }
    }

    private static func stateTint(_ state: CredentialState) -> AnyShapeStyle {
        switch state {
        case .operational:
            return AnyShapeStyle(Color.green)
        case .needsChange, .transport:
            return AnyShapeStyle(Color.orange)
        case .blocked:
            return AnyShapeStyle(Color.red)
        case .unknown:
            return AnyShapeStyle(.secondary)
        }
    }

    private static func outcomeText(_ result: CredentialResult, presented: CredentialKind) -> String {
        if result.outcome == .invalidPin, let retries = result.retriesLeft {
            return loc(
                "libremac_credentials_outcome_invalidPin_attributed",
                "The {who} was not correct — {count} attempt(s) left.",
                placeholders: ["who": kindTitle(presented), "count": String(retries)])
        }
        return outcomeText(result.outcome, presented: presented)
    }

    /// Copy is kept word-for-word in step with LibreKDE's `CredentialText`
    /// table — same wire vocabulary, same sentences, so the two desktop
    /// clients cannot describe one outcome two ways. `invalidPin`/`blocked`
    /// name the credential they are about, as KDE's do; the rest are
    /// credential-independent.
    private static func outcomeText(
        _ outcome: CredentialOutcome, presented: CredentialKind
    ) -> String {
        switch outcome {
        case .unspecified:
            return loc("libremac_credentials_outcome_unspecified",
                       "The operation did not complete.")
        case .ok:
            return loc("libremac_credentials_outcome_ok", "Done.")
        case .userCancelled:
            // Empty on purpose, as in LibreKDE: a cancel is the user's own
            // act, so there is nothing to report back. `statusArea` renders
            // no label for an empty string — hence no catalog key either.
            return ""
        case .missingFields:
            return loc("libremac_credentials_outcome_missingFields",
                       "A required value was not entered.")
        case .invalidPin:
            return attributed("libremac_credentials_outcome_invalidPin",
                              "The {who} was not correct.", presented)
        case .blocked:
            return attributed("libremac_credentials_outcome_blocked",
                              "The {who} is now blocked.", presented)
        case .pluginError:
            return loc("libremac_credentials_outcome_pluginError",
                       "The card reported an error.")
        case .unsupported:
            return loc("libremac_credentials_outcome_unsupported",
                       "This action isn't available on this card.")
        case .keyActivationFailed:
            return loc("libremac_credentials_outcome_keyActivationFailed",
                       "The PIN was set, but activating the signing key failed.")
        case .cardRemoved:
            return loc("libremac_credentials_outcome_cardRemoved",
                       "The card was removed before the operation finished.")
        case .entryExpired:
            return loc("libremac_credentials_outcome_entryExpired",
                       "The entry window closed before a code was entered. Try again.")
        }
    }

    private static func attributed(
        _ key: String, _ fallback: String, _ presented: CredentialKind
    ) -> String {
        loc(key, fallback, placeholders: ["who": kindTitle(presented)])
    }

    /// A cancel is the user's own neutral act — informational chrome, not a
    /// warning; success is green; every failure outcome warns.
    private static func outcomeIcon(_ outcome: CredentialOutcome) -> String {
        switch outcome {
        case .ok:
            return "checkmark.circle.fill"
        case .userCancelled:
            return "info.circle"
        default:
            return "exclamationmark.triangle.fill"
        }
    }

    private static func outcomeTint(_ outcome: CredentialOutcome) -> AnyShapeStyle {
        switch outcome {
        case .ok:
            return AnyShapeStyle(Color.green)
        case .userCancelled:
            return AnyShapeStyle(.secondary)
        default:
            return AnyShapeStyle(Color.orange)
        }
    }

    private static func countText(_ key: String, _ fallback: String, _ count: UInt32) -> String {
        loc(key, fallback, placeholders: ["count": String(count)])
    }

    private static func rangeText(
        _ key: String, _ fallback: String, _ count: UInt32, _ max: UInt32
    ) -> String {
        loc(key, fallback, placeholders: ["count": String(count), "max": String(max)])
    }

    /// Static context cannot reach the environment. This is the SAME object
    /// the environment carries — the app injects `AppLocalization.shared` and
    /// nothing else — so the two paths cannot disagree at runtime. Injecting
    /// a different instance would split the window's language in half.
    @MainActor
    private static func loc(_ key: String, _ fallback: String,
                            placeholders: [String: String] = [:]) -> String {
        AppLocalization.shared.loc(key, fallback, placeholders: placeholders)
    }
}

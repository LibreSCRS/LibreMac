// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The credentials window: a flat dashboard of every present card's
// credential records. Pure presentation over `CredentialsViewModel` — the
// listing/mutation flow and the section lifetime live there; this view only
// initiates listings for the cards `CardMonitor` reports as
// PIN-management-capable and renders what the view model publishes. NO
// secret ever passes through this process: the one live mutation (a PIN
// change) names a record handle and the agent collects the PINs in its own
// secure dialog.

import LibreMacAgentClient
import LibreMacShared
import SwiftUI

struct CredentialsView: View {
    @Environment(CardMonitor.self) var monitor
    let viewModel: CredentialsViewModel

    /// Presentation-only in-flight latch so a double-click cannot start two
    /// mutations; the view model itself is request-at-a-time by usage.
    @State private var busy = false

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
                    Text(Self.countText(
                        "libremac_credentials_retries_left", "{count} attempt(s) left", retries))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let uses = record.usesLeft {
                    Text(Self.countText(
                        "libremac_credentials_uses_left", "{count} use(s) left", uses))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        Text(LocalizedText(key: key, defaultText: fallback ?? "").resolve())
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    /// One button per advertised affordance, strictly from
    /// `viewModel.actions(for:)` (which derives them from the record's
    /// booleans). Only `.change` is driven in this increment — the view
    /// model exposes no unblock / activate operation yet — so the other
    /// three render their advertised titles disabled rather than pretending
    /// to be live.
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
                Button(Self.loc("libremac_credentials_action_unblock", "Unblock…")) {}
                    .disabled(true)
            }
            if actions.contains(.activatePin) {
                Button(Self.loc("libremac_credentials_action_activate_pin", "Activate…")) {}
                    .disabled(true)
            }
            if actions.contains(.activateKey) {
                Button(Self.loc(
                    "libremac_credentials_action_activate_key", "Activate Signing Key…")) {}
                    .disabled(true)
            }
        }
    }

    private func change(card: String, pinId: String) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await viewModel.change(card: card, pinId: pinId)
            busy = false
        }
    }

    // MARK: - Outcome / error status

    /// The most recent request's result line: an entry error renders via the
    /// `ErrorCopy` sync-error table; otherwise the last mutation outcome
    /// renders via its `libremac_credentials_outcome_<token>` copy.
    @ViewBuilder
    private var statusArea: some View {
        if let error = viewModel.entryError {
            Label(
                ErrorCopy.localizedText(for: error).resolve(),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.red)
        } else if let result = viewModel.lastOutcome {
            Label(Self.outcomeText(result.outcome), systemImage: Self.outcomeIcon(result.outcome))
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
            return loc("libremac_credentials_kind_unknown", "Unknown credential")
        }
    }

    private static func stateTitle(_ state: CredentialState) -> String {
        switch state {
        case .unknown:
            return loc("libremac_credentials_state_unknown", "Unknown")
        case .transport:
            return loc("libremac_credentials_state_transport", "Transport (not activated)")
        case .operational:
            return loc("libremac_credentials_state_operational", "Ready")
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

    private static func outcomeText(_ outcome: CredentialOutcome) -> String {
        switch outcome {
        case .unspecified:
            return loc("libremac_credentials_outcome_unspecified",
                       "The operation finished without a reported result.")
        case .ok:
            return loc("libremac_credentials_outcome_ok",
                       "The operation completed successfully.")
        case .userCancelled:
            return loc("libremac_credentials_outcome_userCancelled",
                       "The operation was cancelled.")
        case .missingFields:
            return loc("libremac_credentials_outcome_missingFields",
                       "A required entry was missing.")
        case .invalidPin:
            return loc("libremac_credentials_outcome_invalidPin",
                       "The PIN entered was incorrect.")
        case .blocked:
            return loc("libremac_credentials_outcome_blocked",
                       "The credential is blocked.")
        case .pluginError:
            return loc("libremac_credentials_outcome_pluginError",
                       "The card plugin reported an error.")
        case .unsupported:
            return loc("libremac_credentials_outcome_unsupported",
                       "This operation is not supported on this card.")
        case .keyActivationFailed:
            return loc("libremac_credentials_outcome_keyActivationFailed",
                       "The signing key could not be activated.")
        case .cardRemoved:
            return loc("libremac_credentials_outcome_cardRemoved",
                       "The card was removed before the operation finished.")
        }
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
        LocalizedText(
            key: key, defaultText: fallback, placeholders: ["count": String(count)]
        ).resolve()
    }

    private static func loc(_ key: String, _ fallback: String) -> String {
        LocalizedText(key: key, defaultText: fallback).resolve()
    }
}

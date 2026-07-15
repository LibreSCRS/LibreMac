// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Renders the current `CardMonitor.presence` as a labelled icon in the
// menu-bar popover. Pure presentation — no I/O, no agent calls. The view model
// is injected through SwiftUI's `@Environment` so preview / test hosts can swap
// a fake `CardMonitor` without changing this view.

import LibreMacAgentClient
import LibreMacShared
import SwiftUI

struct CardStatusView: View {
    @Environment(CardMonitor.self) var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Self.title(for: monitor.presence), systemImage: Self.icon(for: monitor.presence))
                .foregroundStyle(Self.tint(for: monitor.presence))

            if monitor.canSign, !monitor.certificates.isEmpty {
                Text(Self.certificateSummary(monitor.certificates.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Presence presentation

    private static func title(for presence: Presence) -> String {
        switch presence {
        case .agentUnavailable:
            return loc("libremac_presence_agent_unavailable", "The signing agent is not running")
        case .noReader:
            return loc("libremac_presence_no_reader", "No reader detected")
        case .readerEmpty:
            return loc("libremac_presence_reader_empty", "Reader connected — insert card")
        case .card(let state):
            return cardTitle(state)
        case .quiesced(let reason):
            return "\(loc("libremac_presence_quiesced", "Session paused")) — \(quiesceTitle(reason))"
        }
    }

    private static func cardTitle(_ state: CardUiState) -> String {
        switch state {
        case .noCard, .none:
            return loc("libremac_presence_reader_empty", "Reader connected — insert card")
        case .preAuthRequired:
            return loc("libremac_presence_preauth", "Card locked — unlock required")
        case .identityOnly:
            return loc("libremac_presence_identity", "Identity card present")
        case .pkiOnly:
            return loc("libremac_presence_pki", "Signing card ready")
        case .hybrid:
            return loc("libremac_presence_hybrid", "ID & signing card ready")
        case .error:
            return loc("libremac_presence_card_error", "Card is not usable")
        }
    }

    private static func quiesceTitle(_ reason: QuiesceReason) -> String {
        switch reason {
        case .systemSleep:
            return loc("libremac_quiesce_system_sleep", "system asleep")
        case .screenLocked:
            return loc("libremac_quiesce_screen_locked", "screen locked")
        case .sessionInactive:
            return loc("libremac_quiesce_session_inactive", "another user is active")
        case .shutdown:
            return loc("libremac_quiesce_shutdown", "shutting down")
        }
    }

    private static func certificateSummary(_ count: Int) -> String {
        LocalizedText(
            key: "libremac_presence_certs_ready",
            defaultText: "{count} certificate(s) ready",
            placeholders: ["count": String(count)]
        ).resolve()
    }

    private static func icon(for presence: Presence) -> String {
        switch presence {
        case .agentUnavailable:
            return "bolt.horizontal.circle"
        case .noReader, .readerEmpty:
            return "creditcard"
        case .card(let state):
            switch state {
            case .pkiOnly, .hybrid: return "checkmark.seal.fill"
            case .identityOnly: return "person.text.rectangle"
            case .preAuthRequired: return "lock.fill"
            case .error, .none, .noCard: return "exclamationmark.triangle.fill"
            }
        case .quiesced:
            return "moon.zzz.fill"
        }
    }

    private static func tint(for presence: Presence) -> AnyShapeStyle {
        switch presence {
        case .card(.pkiOnly), .card(.hybrid):
            return AnyShapeStyle(Color.green)
        case .card(.error):
            return AnyShapeStyle(Color.red)
        case .agentUnavailable:
            return AnyShapeStyle(.secondary)
        default:
            return AnyShapeStyle(.primary)
        }
    }

    private static func loc(_ key: String, _ fallback: String) -> String {
        LocalizedText(key: key, defaultText: fallback).resolve()
    }
}

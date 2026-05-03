// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Pure presentation for the `SigningCoordinator` state machine. The view is
// stateless — the coordinator drives stage transitions, this file only
// renders each stage.

import LibreMacShared
import SwiftUI

struct SignDemoView: View {
    @Environment(CardMonitor.self) var monitor
    @Bindable var coordinator: SigningCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign Demo")
                .font(.headline)

            switch coordinator.stage {
            case .idle:
                Button("Sign demo payload") {
                    coordinator.beginPinEntry()
                }
                .disabled(monitor.activeSession == nil)
            case .awaitingPin:
                if let session = monitor.activeSession {
                    PinEntryView(
                        session: session,
                        onVerified: { _ in
                            Task { await coordinator.pinVerified() }
                        },
                        onCancel: { coordinator.cancelPinEntry() }
                    )
                }
            case .signing:
                ProgressView("Signing…")
            case .done(let signature, let sha):
                Label(
                    "Signed \(coordinator.payload.count) bytes; signature \(signature.count) bytes",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
                Text(
                    "SHA-256(payload): \(sha.prefix(8).map { String(format: "%02x", $0) }.joined())…"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            case .failed(let err):
                Label(
                    err.localizedDescription, systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

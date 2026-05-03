// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// SwiftUI sheet that collects a PIN, hands it to the C bridge wrapped in
// a `SecureString`, and surfaces the verify outcome (retries-left, blocked,
// device error). Used by SignDemoView before any sign() call.
//
// The CTK system PIN dialog is the future system-integration path; this
// is the host-app fallback.
//
// Design rationale:
// - Secure-String discipline: the user's plain-text PIN crosses into a
//   SecureString immediately on submit; the @State String is cleared the
//   instant after, to shrink the in-memory window.
// - Stroustrup, *The C++ Programming Language* §13.5 — RAII semantics:
//   SecureString.deinit zeroes its buffer; the verifyPin call holds the
//   withCString pointer for exactly the duration of the C call.

import LibreMacShared
import SwiftUI

struct PinEntryView: View {
    let session: BridgeSession
    let onVerified: (Int) -> Void  // retries-left, -1 = unknown
    let onCancel: () -> Void

    @State private var pin: String = ""
    @State private var inFlight: Bool = false
    @State private var error: LibreMacError?
    @State private var triesLeft: Int? = nil

    @FocusState private var pinFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter PIN")
                .font(.headline)
            Text("Your PIN never leaves this device.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("", text: $pin)
                .textFieldStyle(.roundedBorder)
                .focused($pinFieldFocused)
                .disabled(inFlight)
                .onSubmit { Task { await submit() } }

            if let triesLeft, triesLeft >= 0 {
                Text("\(triesLeft) tries remaining")
                    .font(.caption)
                    .foregroundStyle(triesLeft <= 1 ? .red : .secondary)
            }

            if let error {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Verify") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.isEmpty || inFlight)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { pinFieldFocused = true }
    }

    private func submit() async {
        inFlight = true
        defer { inFlight = false }
        let secret = SecureString(plaintext: pin)
        // Drop the plain-text immediately after handing it to SecureString.
        pin = ""
        do {
            let retries = try session.verifyPin(secret)
            onVerified(retries)
        } catch {
            self.error = error
            if case .pinIncorrect(let n) = error { triesLeft = n }
        }
    }
}

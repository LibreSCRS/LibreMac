// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// `@Observable` view model that orchestrates the PIN-entry → BridgeSession.sign
// sequence. P2 exit criterion: with an inserted rs-eid card, "Sign demo
// payload" → enter PIN → "Signed N bytes" appears within 1–2 s.
//
// Design notes:
// - The coordinator owns no `BridgeSession` directly. The session lives on
//   the shared `CardMonitor`; the coordinator queries `cardMonitor.activeSession`
//   on demand. This keeps the lifetime invariant simple — when the card is
//   removed, the menu reverts to the no-card UI and the coordinator's
//   `signing` stage is naturally invalidated.
// - SHA-256 of the payload is computed client-side via CryptoKit so the UI
//   can echo a recognisable digest without re-hashing in the verify path.
// - Stroustrup, *A Tour of C++* §17 — prefer the highest-level abstraction
//   that does not sacrifice correctness; CryptoKit is the Apple-native
//   idiom on macOS 15.

import CppBridge
import CryptoKit
import Foundation
import LibreMacShared
import Observation
import os

@Observable
@MainActor
public final class SigningCoordinator {
    public enum Stage: Equatable {
        case idle
        case awaitingPin
        case signing
        case done(signature: Data, payloadSha256: Data)
        case failed(LibreMacError)
    }

    public private(set) var stage: Stage = .idle
    public private(set) var payload: Data = Data(
        "LibreMac demo signing payload — \(Date().ISO8601Format())".utf8)

    private let cardMonitor: CardMonitor

    public init(cardMonitor: CardMonitor) {
        self.cardMonitor = cardMonitor
    }

    public func beginPinEntry() {
        guard cardMonitor.activeSession != nil else { return }
        stage = .awaitingPin
    }

    public func cancelPinEntry() {
        if case .awaitingPin = stage { stage = .idle }
    }

    public func pinVerified() async {
        guard let session = cardMonitor.activeSession else {
            stage = .failed(.bridgeUnavailable(diagnostic: "no active session"))
            return
        }
        stage = .signing
        do {
            let sigData = try session.sign(
                keyReference: defaultKeyReference,
                mechanism: LM_MECH_RSA_PKCS,
                data: payload
            )
            stage = .done(signature: sigData, payloadSha256: Self.sha256(payload))
            Logger.signing.info(
                "Signed \(self.payload.count, privacy: .public) bytes; sig \(sigData.count, privacy: .public) bytes"
            )
        } catch {
            stage = .failed(error)
            Logger.signing.error(
                "Signing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// rs-eid authentication key reference (NIST SP 800-78 / Serbian eID
    /// rs-eid applet's authentication key slot). Hardcoded for now; P3
    /// replaces this with a value enumerated through the bridge's
    /// `discoverKeyReferences` entry point so any plugin family can be
    /// signed with.
    private static let rsEidAuthenticationKeyReference: UInt16 = 0x0010
    private var defaultKeyReference: UInt16 { Self.rsEidAuthenticationKeyReference }

    /// SHA-256 helper. CryptoKit is the Apple-native idiom on macOS 15.
    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Coverage gate for the 20-value ErrorCode → copy table. Every non-`none`
// code MUST have client-localized copy; `.none` MUST defer to the agent's
// msgFallback. Also gates the SyncError overload: the five credential
// entry errors get dedicated, mutually distinct copy; every other name
// keeps rendering as a communication failure.

import Testing
import LibreMacAgentClient
@testable import LibreMac

// `message(for:msgFallback:)` resolves through the host's localization
// object, which is main-actor isolated, so the whole suite runs there.
@Suite("ErrorCopy")
@MainActor
struct ErrorCopyTests {

    @Test("every non-none code has localized copy; none has not")
    func everyNonNoneCodeIsLocalized() {
        for code in ErrorCode.allCases {
            if code == .none {
                #expect(ErrorCopy.localizedText(for: code) == nil)
            } else {
                #expect(ErrorCopy.localizedText(for: code) != nil,
                        "missing localized copy for \(code)")
            }
        }
    }

    @Test("the taxonomy still has exactly 20 values")
    func taxonomyHasTwentyValues() {
        #expect(ErrorCode.allCases.count == 20)
    }

    @Test("none falls back to the agent-provided msgFallback verbatim")
    func noneFallsBackToMsgFallback() {
        let fallback = "agent authored this"
        #expect(ErrorCopy.message(for: .none, msgFallback: fallback) == fallback)
    }

    @Test("an unrecognized (future) code falls back to the agent-provided msgFallback, like .none")
    func unknownCodeFallsBackToMsgFallback() {
        let fallback = "a future agent's authored message"
        #expect(ErrorCopy.localizedText(for: .unknown(10000)) == nil)
        #expect(ErrorCopy.message(for: .unknown(10000), msgFallback: fallback) == fallback)
    }

    @Test("a localized code ignores the fallback and returns non-empty copy")
    func localizedCodeReturnsNonEmpty() {
        let message = ErrorCopy.message(for: .credentialWrong, msgFallback: "")
        #expect(!message.isEmpty)
    }

    // MARK: - Sync-error copy (credentials entry gates)

    /// The five named entry errors the credentials request gates surface
    /// (capability, validation ×2, authorization, rate limit) — each MUST
    /// carry its own dedicated copy.
    private static let credentialEntryErrors: [SyncError] = [
        .unsupportedOnThisCard, .notAuthorized, .rateLimited,
        .unknownCredential, .invalidRequest,
    ]

    @Test("each credential entry error yields its own distinct copy")
    func credentialEntryErrorCopyIsDistinct() {
        let texts = Self.credentialEntryErrors.map { ErrorCopy.localizedText(for: $0) }
        #expect(Set(texts.map(\.key)).count == texts.count,
                "credential entry errors share a copy key")
        #expect(Set(texts.map(\.defaultText)).count == texts.count,
                "credential entry errors share fallback copy")
        for text in texts {
            #expect(text.key.hasPrefix("libremac_credentials_err_"),
                    "unexpected key \(text.key)")
            #expect(!text.defaultText.isEmpty)
        }
    }

    @Test("credential entry errors do not reuse the communication copy")
    func credentialEntryErrorCopyIsNotCommunication() {
        let communication = ErrorCopy.localizedText(for: ErrorCode.communicationError)
        #expect(communication != nil)
        for error in Self.credentialEntryErrors {
            let text = ErrorCopy.localizedText(for: error)
            #expect(text.key != communication?.key,
                    "\(error) reuses the communication key")
            #expect(text.defaultText != communication?.defaultText,
                    "\(error) reuses the communication copy")
        }
    }

    @Test("every other sync error falls back to the communication copy")
    func otherSyncErrorsFallBackToCommunicationCopy() {
        let communication = ErrorCopy.localizedText(for: ErrorCode.communicationError)
        for error in SyncError.allCases
        where !Self.credentialEntryErrors.contains(error) {
            let text = ErrorCopy.localizedText(for: error)
            #expect(text.key == communication?.key,
                    "\(error) should render as a communication failure")
            #expect(text.defaultText == communication?.defaultText,
                    "\(error) should carry the communication fallback copy")
        }
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Coverage gate for the 20-value ErrorCode → copy table. Every non-`none`
// code MUST have client-localized copy; `.none` MUST defer to the agent's
// msgFallback. Also gates the SyncError overload: the five credential
// entry errors get dedicated, mutually distinct copy; a dismissed prompt gets
// its own and is asserted NOT to be the communication one; every other name
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

    @Test("the taxonomy still has exactly 21 values")
    func taxonomyHasTwentyOneValues() {
        #expect(ErrorCode.allCases.count == 21)
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

    /// Names that must NOT render as a communication failure but are not
    /// credential entry errors either. `.cancelled` is the person answering
    /// the prompt with "no": the card is fine and nothing was refused.
    ///
    /// It lives in its own list rather than in the one above because the
    /// fallback test below iterates `SyncError.allCases`, so an appended name
    /// is swept into it AUTOMATICALLY. Left in that loop, `.cancelled` would
    /// be asserted to render "Communication with the card reader failed." —
    /// pinning the one outcome the separate wire name exists to prevent. A
    /// test that pins the answer a name was added to avoid is worse than no
    /// test.
    private static let nonFailureErrors: [SyncError] = [.cancelled]

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
        where !Self.credentialEntryErrors.contains(error)
            && !Self.nonFailureErrors.contains(error) {
            let text = ErrorCopy.localizedText(for: error)
            #expect(text.key == communication?.key,
                    "\(error) should render as a communication failure")
            #expect(text.defaultText == communication?.defaultText,
                    "\(error) should carry the communication fallback copy")
        }
    }

    /// The exemption above only stops this suite from PINNING the wrong
    /// answer. This is the assertion that makes it a gate: a cancel must not
    /// reach the user as a broken exchange, on this surface or any other.
    /// Deleting the exemption without this test leaves the anti-gate; adding
    /// this test without the exemption leaves the suite contradicting itself.
    @Test("a dismissed prompt does not render as a communication failure")
    func cancelledDoesNotRenderAsCommunicationFailure() {
        let communication = ErrorCopy.localizedText(for: ErrorCode.communicationError)
        #expect(communication != nil)
        for error in Self.nonFailureErrors {
            let text = ErrorCopy.localizedText(for: error)
            #expect(text.key != communication?.key,
                    "\(error) reuses the communication key")
            #expect(text.defaultText != communication?.defaultText,
                    "\(error) reuses the communication copy")
            #expect(!text.defaultText.isEmpty)
        }
    }

    /// Every name is either a credential entry error, a non-failure, or a
    /// communication fallback — and nothing is in two lists at once. Both
    /// lists take names OUT of the fallback loop above, so each name they
    /// take out must earn it by carrying an answer of its own: without that,
    /// adding a name to either list and forgetting to give it copy would
    /// simply shrink the loop and pass. The last expectation keeps the loop
    /// from being emptied altogether.
    @Test("the exemption lists do not overlap, and every exempted name earns its exemption")
    func exemptionListsPartitionTheVocabulary() {
        let entry = Set(Self.credentialEntryErrors)
        let nonFailure = Set(Self.nonFailureErrors)
        #expect(entry.isDisjoint(with: nonFailure),
                "a name is claimed by both lists: \(entry.intersection(nonFailure))")
        let communication = ErrorCopy.localizedText(for: ErrorCode.communicationError)
        #expect(communication != nil)
        for error in entry.union(nonFailure) {
            let text = ErrorCopy.localizedText(for: error)
            #expect(text.key != communication?.key,
                    "\(error) is exempted from the fallback yet renders as one")
            #expect(text.defaultText != communication?.defaultText,
                    "\(error) is exempted from the fallback yet carries its copy")
            #expect(!text.defaultText.isEmpty, "\(error) is exempted and has no copy at all")
        }
        #expect(!Set(SyncError.allCases).subtracting(entry).subtracting(nonFailure).isEmpty,
                "every name is exempted — the fallback assertion above walks nothing")
    }
}

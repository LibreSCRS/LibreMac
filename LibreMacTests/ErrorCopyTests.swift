// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Coverage gate for the 18-value ErrorCode → copy table. Every non-`none`
// code MUST have client-localized copy; `.none` MUST defer to the agent's
// msgFallback.

import Testing
import LibreMacAgentClient
@testable import LibreMac

@Suite("ErrorCopy")
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

    @Test("the taxonomy still has exactly 18 values")
    func taxonomyHasEighteenValues() {
        #expect(ErrorCode.allCases.count == 18)
    }

    @Test("none falls back to the agent-provided msgFallback verbatim")
    func noneFallsBackToMsgFallback() {
        let fallback = "agent authored this"
        #expect(ErrorCopy.message(for: .none, msgFallback: fallback) == fallback)
    }

    @Test("a localized code ignores the fallback and returns non-empty copy")
    func localizedCodeReturnsNonEmpty() {
        let message = ErrorCopy.message(for: .credentialWrong, msgFallback: "")
        #expect(!message.isEmpty)
    }
}

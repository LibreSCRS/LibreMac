// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
@testable import LibreMacAgentClient

// `PromptBudget.maxSequential` is vendored, not computed -- see that type's
// doc comment. This file holds it against `Contract/prompt-policy.txt` (the
// vendored number itself) and against the two socket clients that must
// outlive it: a transport timeout shorter than the budget it is meant to
// carry fires before the agent's own deadline could, which turns a prompt
// the agent is still legitimately waiting on into a client-side failure.

private func vendoredMaxSequentialMs() throws -> Int {
    let url = try #require(
        Bundle.module.url(forResource: "prompt-policy", withExtension: "txt", subdirectory: "Contract"))
    let contents = try String(contentsOf: url, encoding: .utf8)
    let fields = contents.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    try #require(fields.count == 2 && fields[0] == "max-sequential-ms",
                 "prompt-policy.txt is not in the expected 'max-sequential-ms <n>' shape: \(contents)")
    return try #require(Int(fields[1]))
}

@Test func maxSequentialMatchesTheVendoredContract() throws {
    #expect(PromptBudget.maxSequential * 1000 == Double(try vendoredMaxSequentialMs()))
}

@Test func tokenClientIoTimeoutOutlivesTheBudget() {
    #expect(TokenAgentClient.defaultIoTimeout > PromptBudget.maxSequential)
}

@Test func hostClientConfirmableTimeoutOutlivesTheBudget() {
    #expect(AgentClient.defaultConfirmableTimeout > PromptBudget.maxSequential)
}

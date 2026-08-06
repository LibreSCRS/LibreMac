// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The stored default level is not always the effective one. The pane says so
// rather than re-deriving the rule, which lives in the signing consumer.

import LibreMacAgentClient
import Testing

@testable import LibreMac

@Suite("Signing pane")
@MainActor
struct SigningPaneTests {

    @Test("the level popup offers the mirror minus the request-only sentinel")
    func levelOptionsExcludeAuto() {
        let options = SigningPane.levelOptions()

        #expect(options == SignatureLevel.allCases.filter { $0 != .auto })
        #expect(
            !options.contains(.auto),
            "auto is request-only; a stored default of auto is circular")
    }

    @Test("a stored baseline with a TSA configured says timestamping applies")
    func baselineWithTsaIsAdvised() {
        #expect(
            SigningPane.advisory(level: "b-b", tsaConfigured: true) != nil,
            "the agent raises b-b to b-t once a TSA is set; the pane must not stay silent")
    }

    @Test("a long-term level with no TSA is flagged")
    func longTermWithoutTsaIsFlagged() {
        #expect(SigningPane.advisory(level: "b-lta", tsaConfigured: false) != nil)
        #expect(SigningPane.advisory(level: "b-t", tsaConfigured: false) != nil)
    }

    @Test("a consistent combination is not nagged about")
    func consistentCombinationIsQuiet() {
        #expect(SigningPane.advisory(level: "b-b", tsaConfigured: false) == nil)
        #expect(SigningPane.advisory(level: "b-t", tsaConfigured: true) == nil)
    }

    /// An unreachable agent blanks every row, so the pane would otherwise be
    /// advising about a level nobody has read. "No timestamping authority
    /// configured" is a claim about the agent's state; with no reading of
    /// that state there is nothing to claim.
    @Test("a level that was never read is not advised about")
    func unreadLevelIsQuiet() {
        #expect(SigningPane.advisory(level: "", tsaConfigured: false) == nil)
        #expect(SigningPane.advisory(level: "", tsaConfigured: true) == nil)
    }

    /// The level vocabulary is append-only. A name this build does not know
    /// gets no advisory rather than a guess at what it implies.
    @Test("a level this build does not know is not advised about")
    func unknownLevelIsQuiet() {
        #expect(SigningPane.advisory(level: "b-future", tsaConfigured: false) == nil)
        #expect(SigningPane.advisory(level: "auto", tsaConfigured: false) == nil)
    }

    /// The two advisories are different situations and must read differently;
    /// one shared sentence would tell the user nothing about which applies.
    @Test("the two advisories are distinct sentences")
    func advisoriesAreDistinct() {
        let applies = SigningPane.advisory(level: "b-b", tsaConfigured: true)
        let missing = SigningPane.advisory(level: "b-lta", tsaConfigured: false)

        #expect(applies != missing)
        #expect(applies?.isEmpty == false)
        #expect(missing?.isEmpty == false)
    }
}

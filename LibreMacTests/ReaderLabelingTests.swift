// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import LibreMacAgentClient
import Testing

@testable import LibreMac

// Plain-text formatters standing in for the localized ones (keeps assertions
// deterministic and locale-independent).
private let contactFmt: @Sendable (String) -> String = { "\($0) — contact" }
private let contactlessFmt: @Sendable (String) -> String = { "\($0) — contactless" }

private func label(_ reader: ReaderState) -> String {
    readerDisplayLabel(reader, contact: contactFmt, contactless: contactlessFmt)
}

// The name each reader carries is one this host used to parse into a label.
// Every expectation below differs from what that parse made of it, so a label
// read from the name instead of from the agent's fields fails here.
private let omnikeyName =
    "HID Global OMNIKEY 5422 Smartcard Reader [OMNIKEY 5422CL Smartcard Reader] (IM0O2C00NF10456904) 00 00"

@Suite("Reader labeling")
struct ReaderLabelingTests {

    @Test("a reader with no particular interface shows the agent's model as it is")
    func modelOnly() {
        let r = ReaderState(
            handle: "R1", name: "Gemalto PC Twin Reader 00 00", hasCard: true,
            model: "Agent Model 1", interface: .unknown)
        #expect(label(r) == "Agent Model 1")
    }

    @Test("the slots of a dual-interface unit are worded by the interface the agent names")
    func dualInterface() {
        let contact = ReaderState(
            handle: "R1", name: omnikeyName, hasCard: true, model: "OMNIKEY 5422", interface: .contact)
        let contactless = ReaderState(
            handle: "R2", name: omnikeyName, hasCard: false, model: "OMNIKEY 5422", interface: .contactless)
        #expect(label(contact) == "OMNIKEY 5422 — contact")
        #expect(label(contactless) == "OMNIKEY 5422 — contactless")
    }

    @Test("the agent's model is not reworded: a twin's tail it added stays as sent")
    func modelIsNotReparsed() {
        let r = ReaderState(
            handle: "R1", name: "ACME Card Reader (1234) 00 00", hasCard: true,
            model: "ACME Card Reader (1234)", interface: .unknown)
        #expect(label(r) == "ACME Card Reader (1234)")
    }

    @Test("an agent that sends no label leaves the PC/SC name, unparsed")
    func noLabelShowsTheName() {
        let r = ReaderState(handle: "R1", name: omnikeyName, hasCard: true)
        #expect(r.model == nil)
        #expect(label(r) == omnikeyName)
    }
}

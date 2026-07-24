// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import LibreMacAgentClient
import Testing

@testable import LibreMac

private func reader(_ handle: String, _ name: String) -> ReaderState {
    ReaderState(handle: handle, name: name, hasCard: true, card: nil)
}

// Plain-text formatters standing in for the localized ones (keeps assertions
// deterministic and locale-independent).
private let contactFmt: @Sendable (String) -> String = { "\($0) — contact" }
private let contactlessFmt: @Sendable (String) -> String = { "\($0) — contactless" }

@Suite("Reader labeling")
struct ReaderLabelingTests {

    @Test("parseReaderName flags contactless from picc/nfc/CL markers")
    func contactlessDetection() {
        #expect(parseReaderName("ACS ACR122U PICC Interface (00) 00 00").contactless == true)
        #expect(parseReaderName("Some NFC Reader 00 00").contactless == true)
        #expect(parseReaderName("Gemalto PC Twin Reader 00 00").contactless == false)
    }

    @Test("a lone reader shows a bare cleaned model")
    func loneReader() {
        let labels = readerDisplayLabels(
            [reader("R1", "Gemalto PC Twin Reader 00 00")],
            contact: contactFmt, contactless: contactlessFmt)
        #expect(labels["R1"] == "Gemalto PC Twin")
    }

    @Test("a dual-interface device disambiguates contact vs contactless")
    func dualInterface() {
        let readers = [
            reader("R1", "HID OMNIKEY 5422 Smartcard Reader [OMNIKEY 5422 Smartcard Reader] (0000) 00 00"),
            reader("R2", "HID OMNIKEY 5422 CL Reader [OMNIKEY 5422CL Reader] (0000) 01 00"),
        ]
        let labels = readerDisplayLabels(readers, contact: contactFmt, contactless: contactlessFmt)
        #expect(labels["R1"] == "OMNIKEY 5422 — contact")
        #expect(labels["R2"] == "OMNIKEY 5422 — contactless")
    }

    @Test("two identical readers are disambiguated by serial tail")
    func identicalReaders() {
        let readers = [
            reader("R1", "ACME Card Reader (1234) 00 00"),
            reader("R2", "ACME Card Reader (5678) 00 00"),
        ]
        let labels = readerDisplayLabels(readers, contact: contactFmt, contactless: contactlessFmt)
        #expect(labels["R1"] == "ACME Card (1234)")
        #expect(labels["R2"] == "ACME Card (5678)")
    }

    @Test("an un-parseable name falls back to the raw name, never empty")
    func rawFallback() {
        let labels = readerDisplayLabels(
            [reader("R1", "USB")], contact: contactFmt, contactless: contactlessFmt)
        #expect(labels["R1"] == "USB")
    }

    @Test("a third distinct reader is labelled independently")
    func thirdReader() {
        let readers = [
            reader("R1", "Gemalto PC Twin Reader 00 00"),
            reader("R2", "ACME Card Reader (1234) 00 00"),
            reader("R3", "Some NFC Reader 00 00"),
        ]
        let labels = readerDisplayLabels(readers, contact: contactFmt, contactless: contactlessFmt)
        #expect(labels["R1"] == "Gemalto PC Twin")
        #expect(labels["R3"]?.hasSuffix("— contactless") == true)
        #expect(labels.count == 3)
    }
}

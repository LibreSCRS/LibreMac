// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import Testing
@testable import LibreMacAgentClient

// The rows and collision cases of the Qt client library's `SignedOutputPathTest`,
// so both implementations of the one naming rule are held by the same cases.
// Literals, not derived from the code under test.

@Suite("SignedOutputName")
struct SignedOutputNameTests {

    struct Row: Sendable, CustomTestStringConvertible {
        var testDescription: String { "\(input) \(format) \(packaging)" }
        let input: String
        let format: SignatureFormat
        let packaging: Packaging
        let expected: String
    }

    static let rows: [Row] = [
        Row(input: "contract.pdf", format: .pades, packaging: .enveloped, expected: "contract-signed.pdf"),
        Row(input: "contract.pdf", format: .pades, packaging: .detached, expected: "contract-signed.pdf"),
        Row(input: "invoice.xml", format: .xades, packaging: .enveloped, expected: "invoice-signed.xml"),
        Row(input: "invoice.xml", format: .xades, packaging: .detached, expected: "invoice.xml.xsig"),
        Row(input: "data.bin", format: .cades, packaging: .detached, expected: "data.bin.p7s"),
        Row(input: "data.bin", format: .cades, packaging: .enveloped, expected: "data.bin.p7m"),
        Row(input: "claims.json", format: .jades, packaging: .detached, expected: "claims.json.jose"),
        Row(input: "photo.jpg", format: .asice, packaging: .detached, expected: "photo.asice"),
        Row(input: "archive.tar.gz", format: .pades, packaging: .enveloped, expected: "archive.tar-signed.pdf"),
    ]

    @Test("every format and packaging has one name", arguments: rows)
    func everyFormatAndPackagingHasOneName(row: Row) {
        let folder = URL(fileURLWithPath: "/tmp/in")
        let url = SignedOutputName.url(
            forInput: folder.appendingPathComponent(row.input),
            format: row.format, packaging: row.packaging, in: folder, isTaken: { _ in false })
        #expect(url?.lastPathComponent == row.expected)
    }

    @Test("a folder replaces the input's directory")
    func folderReplacesTheInputsDirectory() {
        let url = SignedOutputName.url(
            forInput: URL(fileURLWithPath: "/in/a.pdf"), format: .pades, packaging: .enveloped,
            in: URL(fileURLWithPath: "/out"), isTaken: { _ in false })
        #expect(url?.path == "/out/a-signed.pdf")
    }

    @Test("a taken name gets the first free numbered sibling")
    func takenNameGetsFirstFreeSibling() {
        let taken: Set<String> = ["contract-signed.pdf", "contract-signed (2).pdf"]
        let url = SignedOutputName.url(
            forInput: URL(fileURLWithPath: "/d/contract.pdf"), format: .pades, packaging: .enveloped,
            in: URL(fileURLWithPath: "/d"), isTaken: { taken.contains($0.lastPathComponent) })
        #expect(url?.lastPathComponent == "contract-signed (3).pdf")
    }

    @Test("the number goes before the last extension")
    func numberGoesBeforeTheLastExtension() {
        let url = SignedOutputName.url(
            forInput: URL(fileURLWithPath: "/d/invoice.xml"), format: .xades, packaging: .detached,
            in: URL(fileURLWithPath: "/d"), isTaken: { $0.lastPathComponent == "invoice.xml.xsig" })
        #expect(url?.lastPathComponent == "invoice.xml (2).xsig")
    }

    @Test("no free name is nil, never a taken one")
    func exhaustedSearchIsNil() {
        let url = SignedOutputName.url(
            forInput: URL(fileURLWithPath: "/d/x.pdf"), format: .pades, packaging: .enveloped,
            in: URL(fileURLWithPath: "/d"), isTaken: { _ in true })
        #expect(url == nil)
    }

    @Test("a deferred format or packaging names no file")
    func deferralNamesNoFile() {
        #expect(SignedOutputName.name(forInputName: "a.pdf", format: .auto, packaging: .detached) == nil)
        #expect(SignedOutputName.name(forInputName: "a.pdf", format: .cades, packaging: .auto) == nil)
    }
}

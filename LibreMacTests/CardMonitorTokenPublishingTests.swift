// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Card-free tests for the CardMonitor -> TokenIdentityRegistrar wiring.
// `CardMonitor.publishableCerts` is a pure static helper (no `AgentClient`
// dependency — DER resolution is a plain stub closure), so the whole
// card-present -> publish / card-removed -> clear path is exercised here
// against a real `TokenIdentityRegistrar` backed by a fake `TokenConfigStore`,
// without a running agent connection or a physical card.

import CryptoKit
import Foundation
import Testing
import LibreMacAgentClient
@testable import LibreMac

// Reuses `FakeTokenConfigStore`, declared (internal, not private) in
// `TokenIdentityRegistrarTests.swift` — no need for a second in-memory
// `TokenConfigStore` fake in this file.

/// Anchor class purely so `Bundle(for:)` resolves the test bundle — the
/// `Testing` framework's `struct` test cases have no `NSObject` of their own.
private final class TestBundleAnchor {}

private func realCertDER() throws -> Data {
    let url = try #require(
        Bundle(for: TestBundleAnchor.self).url(forResource: "test-cert", withExtension: "der"))
    return try Data(contentsOf: url)
}

private func sha256hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func certInfo(
    certId: String, signingCapable: Bool, keyUsageBits: UInt32 = 0
) -> CertificateInfo {
    CertificateInfo(
        certId: certId, signingCapable: signingCapable, fields: [:],
        keyUsageBits: keyUsageBits, ekus: [], chainSubjectCns: [], trustStatus: 0)
}

@Suite("CardMonitor token publishing")
struct CardMonitorTokenPublishingTests {

    @Test("publishableCerts resolves DER only for signing-capable certs and sets isQualified from bit 1")
    func publishableCertsFiltersAndResolves() async throws {
        let der = try realCertDER()
        let certId = sha256hex(der)
        let signingCert = certInfo(certId: certId, signingCapable: true, keyUsageBits: 1 << 1)
        let authOnlyCert = certInfo(certId: "auth-only", signingCapable: false)

        var fetchedFor: [String] = []
        let publishable = await CardMonitor.publishableCerts(
            [signingCert, authOnlyCert], reader: "reader:0"
        ) { reader, certId in
            fetchedFor.append(certId)
            #expect(reader == "reader:0")
            return der
        }

        #expect(fetchedFor == [certId], "only the signing-capable cert's DER is fetched")
        #expect(publishable.count == 1)
        #expect(publishable.first?.certId == certId)
        #expect(publishable.first?.der == der)
        #expect(publishable.first?.isQualified == true, "bit 1 of keyUsageBits is nonRepudiation")
    }

    @Test("a signing-capable cert without the nonRepudiation bit is not qualified")
    func unqualifiedBitIsNotQualified() async throws {
        let der = try realCertDER()
        let certId = sha256hex(der)
        let signingCert = certInfo(certId: certId, signingCapable: true, keyUsageBits: 1 << 0)

        let publishable = await CardMonitor.publishableCerts(
            [signingCert], reader: "reader:0"
        ) { _, _ in der }

        #expect(publishable.first?.isQualified == false)
    }

    @Test("a DER fetch failure skips that cert rather than aborting the batch")
    func derFetchFailureSkipsCert() async throws {
        struct FetchError: Error {}
        let signingCert = certInfo(certId: "will-fail", signingCapable: true)

        let publishable = await CardMonitor.publishableCerts(
            [signingCert], reader: "reader:0"
        ) { _, _ in throw FetchError() }

        #expect(publishable.isEmpty)
    }

    @Test("card present publishes to the registrar; card removed clears it")
    func presenceDrivesRegistrar() async throws {
        let der = try realCertDER()
        let certId = sha256hex(der)
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let signingCert = certInfo(certId: certId, signingCapable: true)

        let publishable = await CardMonitor.publishableCerts(
            [signingCert], reader: "reader:0"
        ) { _, _ in der }
        registrar.onCardPresent(certs: publishable)

        #expect(
            store.tokens["librescrs-\(certId)"] != nil,
            "the signing cert's instance id was published")

        registrar.onCardRemoved()
        #expect(store.tokens.isEmpty, "removal clears every published instance id")
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Publish/remove-on-eject tests for TokenIdentityRegistrar against a fake
// TokenConfigStore. Exercises the real SHA-256 + DER-parse gate against a
// real self-signed certificate fixture (`Fixtures/test-cert.der`) rather
// than a synthetic DER, so a parse failure in the gate cannot pass silently.

import CryptoKit
import Foundation
import Testing
@testable import LibreMac

/// In-memory `TokenConfigStore` recording every add/remove call.
final class FakeTokenConfigStore: TokenConfigStore {
    private(set) var tokens: [String: [Any]] = [:]

    func addToken(instanceID: String, items: [Any]) {
        tokens[instanceID] = items
    }

    func removeToken(instanceID: String) {
        tokens[instanceID] = nil
    }

    func clearAll() {
        tokens.removeAll()
    }
}

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

@Suite("TokenIdentityRegistrar")
struct TokenIdentityRegistrarTests {

    @Test("publishes a real cert on presence, then clears it on removal")
    func publishesRealCertThenRemovesOnEject() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try realCertDER()
        let certId = sha256hex(der)

        registrar.onCardPresent(certs: [PublishableCert(certId: certId, der: der, isQualified: false)])
        #expect(store.tokens.count == 1, "one token configuration per published cert")

        registrar.onCardRemoved()
        #expect(store.tokens.isEmpty)
    }

    @Test("never publishes when the claimed certId does not match SHA-256(DER)")
    func rejectsCertWhenSha256DoesNotMatchCertId() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try realCertDER()

        registrar.onCardPresent(certs: [PublishableCert(certId: "deadbeef", der: der, isQualified: false)])
        #expect(store.tokens.isEmpty, "certId != sha256(DER) must never publish")
    }

    @Test("reregisterOnLaunch clears any stale publication before republishing")
    func reregisterOnLaunchRecycles() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try realCertDER()
        let certId = sha256hex(der)
        let cert = PublishableCert(certId: certId, der: der, isQualified: false)

        registrar.onCardPresent(certs: [cert])
        #expect(store.tokens.count == 1)

        registrar.reregisterOnLaunch(currentCerts: [cert])
        #expect(store.tokens.count == 1, "recycle republishes exactly one configuration, not a duplicate")
    }

    @Test("reregisterOnLaunch clears a stale store entry even on a brand-new registrar instance")
    func reregisterOnLaunchClearsStaleEntryOnFreshInstance() throws {
        // Simulates the actual launch case: a stale `TKTokenDriverConfiguration`
        // entry survives from a prior process (FB22701547), and the
        // `TokenIdentityRegistrar` constructed at this launch has never seen
        // it — its in-memory `published` set starts empty. Recycling on
        // launch must not depend on that set to find what to clear.
        let store = FakeTokenConfigStore()
        store.addToken(instanceID: "librescrs-stale", items: [])
        let registrar = TokenIdentityRegistrar(store: store)

        registrar.reregisterOnLaunch(currentCerts: [])

        #expect(store.tokens.isEmpty, "a stale entry unknown to this instance's published set must still be cleared")
    }

    @Test("a qualified cert is skipped unless LIBRESCRS_ENABLE_QES_KEYCHAIN is set")
    func qualifiedCertGatedByDefault() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try realCertDER()
        let certId = sha256hex(der)

        registrar.onCardPresent(certs: [PublishableCert(certId: certId, der: der, isQualified: true)])
        #expect(
            ProcessInfo.processInfo.environment["LIBRESCRS_ENABLE_QES_KEYCHAIN"] != "1",
            "test process must not have opted in for this assertion to be meaningful")
        #expect(store.tokens.isEmpty, "qualified certs are gated off by default")
    }
}

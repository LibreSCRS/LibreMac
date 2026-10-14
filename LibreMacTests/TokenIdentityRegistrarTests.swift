// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Publish/remove-on-eject tests for TokenIdentityRegistrar against a fake
// TokenConfigStore. Exercises the real SHA-256 + DER-parse gate against a
// real self-signed certificate fixture (`Fixtures/test-cert.der`) rather
// than a synthetic DER, so a parse failure in the gate cannot pass silently.

import CryptoKit
import CryptoTokenKit
import Foundation
import LibreMacAgentClient
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

private func ecCertDER() throws -> Data {
    let url = try #require(
        Bundle(for: TestBundleAnchor.self).url(forResource: "test-cert-p384", withExtension: "der"))
    return try Data(contentsOf: url)
}

private func publishedKey(_ store: FakeTokenConfigStore) -> TKTokenKeychainKey? {
    store.tokens.values.first?.compactMap { $0 as? TKTokenKeychainKey }.first
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

        registrar.onCardPresent(certs: [PublishableCert(certId: certId, der: der, isQualified: false, keyType: .rsa, signingCapable: true, canDerive: false)])
        #expect(store.tokens.count == 1, "one token configuration per published cert")

        registrar.onCardRemoved()
        #expect(store.tokens.isEmpty)
    }

    @Test("never publishes when the claimed certId does not match SHA-256(DER)")
    func rejectsCertWhenSha256DoesNotMatchCertId() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try realCertDER()

        registrar.onCardPresent(certs: [PublishableCert(certId: "deadbeef", der: der, isQualified: false, keyType: .rsa, signingCapable: true, canDerive: false)])
        #expect(store.tokens.isEmpty, "certId != sha256(DER) must never publish")
    }

    @Test("reregisterOnLaunch clears any stale publication before republishing")
    func reregisterOnLaunchRecycles() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try realCertDER()
        let certId = sha256hex(der)
        let cert = PublishableCert(certId: certId, der: der, isQualified: false, keyType: .rsa, signingCapable: true, canDerive: false)

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

        registrar.onCardPresent(certs: [PublishableCert(certId: certId, der: der, isQualified: true, keyType: .rsa, signingCapable: true, canDerive: false)])
        #expect(
            ProcessInfo.processInfo.environment["LIBRESCRS_ENABLE_QES_KEYCHAIN"] != "1",
            "test process must not have opted in for this assertion to be meaningful")
        #expect(store.tokens.isEmpty, "qualified certs are gated off by default")
    }

    @Test("an EC P-384 card key is published as an EC signing key of its size")
    func publishesAnEcKey() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try ecCertDER()
        registrar.onCardPresent(certs: [PublishableCert(certId: sha256hex(der), der: der, isQualified: false,
                                                        keyType: .ec, signingCapable: true, canDerive: false)])
        let key = try #require(publishedKey(store))
        #expect(key.keyType == kSecAttrKeyTypeECSECPrimeRandom as String)
        #expect(key.keySizeInBits == 384)
        #expect(key.canSign)
        #expect(!key.canPerformKeyExchange, "no key exchange unless the agent derives with this key")
    }

    @Test("a key the agent reports as another kind is never published")
    func otherKeyIsNotPublished() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try ecCertDER()
        registrar.onCardPresent(certs: [PublishableCert(certId: sha256hex(der), der: der, isQualified: false,
                                                        keyType: .other, signingCapable: true, canDerive: false)])
        #expect(store.tokens.isEmpty)
    }

    @Test("a key the agent cannot sign with is not published")
    func nonSigningKeyIsNotPublished() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try realCertDER()
        registrar.onCardPresent(certs: [PublishableCert(certId: sha256hex(der), der: der, isQualified: false,
                                                        keyType: .rsa, signingCapable: false, canDerive: false)])
        #expect(store.tokens.isEmpty, "a key that neither signs nor derives has nothing to publish")
    }

    @Test("an EC key the agent derives with can perform key exchange")
    func ecKeyThatDerivesCanPerformKeyExchange() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try ecCertDER()
        registrar.onCardPresent(certs: [PublishableCert(certId: sha256hex(der), der: der, isQualified: false,
                                                        keyType: .ec, signingCapable: true, canDerive: true)])
        let key = try #require(publishedKey(store))
        #expect(key.canPerformKeyExchange)
        let constraints = try #require(key.constraints)
        #expect(constraints[NSNumber(value: TKTokenOperation.performKeyExchange.rawValue)] != nil)
        #expect(constraints[NSNumber(value: TKTokenOperation.signData.rawValue)] != nil)
    }

    @Test("a key that only derives is published for key exchange alone")
    func deriveOnlyKeyIsPublishedWithoutSign() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try ecCertDER()
        registrar.onCardPresent(certs: [PublishableCert(certId: sha256hex(der), der: der, isQualified: false,
                                                        keyType: .ec, signingCapable: false, canDerive: true)])
        let key = try #require(publishedKey(store))
        #expect(!key.canSign)
        #expect(key.canPerformKeyExchange)
        let constraints = try #require(key.constraints)
        #expect(constraints[NSNumber(value: TKTokenOperation.signData.rawValue)] == nil)
    }

    @Test("no published key is offered for decryption, whatever its certificate allows", arguments: [false, true])
    func noKeyIsOfferedForDecryption(ec: Bool) throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try ec ? ecCertDER() : realCertDER()
        registrar.onCardPresent(certs: [PublishableCert(certId: sha256hex(der), der: der, isQualified: false,
                                                        keyType: ec ? .ec : .rsa, signingCapable: true,
                                                        canDerive: ec)])
        let key = try #require(publishedKey(store))
        #expect(!key.canDecrypt, "the token never decrypts")
    }

    @Test("an RSA key is never offered key exchange, whatever the agent reports")
    func rsaKeyIsNeverOfferedKeyExchange() throws {
        let store = FakeTokenConfigStore()
        let registrar = TokenIdentityRegistrar(store: store)
        let der = try realCertDER()
        registrar.onCardPresent(certs: [PublishableCert(certId: sha256hex(der), der: der, isQualified: false,
                                                        keyType: .rsa, signingCapable: true, canDerive: true)])
        let key = try #require(publishedKey(store))
        #expect(key.canSign)
        #expect(!key.canPerformKeyExchange)
        let constraints = try #require(key.constraints)
        #expect(constraints[NSNumber(value: TKTokenOperation.performKeyExchange.rawValue)] == nil)
    }
}

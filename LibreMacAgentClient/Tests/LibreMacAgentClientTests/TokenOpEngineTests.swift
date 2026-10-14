// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import CryptoKit
import Foundation
import Testing
@testable import LibreMacAgentClient

@Suite("TokenOpEngine")
struct TokenOpEngineTests {

    /// A scripted `TokenTransport` double: each call to `send` pops and
    /// invokes the next closure in `script`, recording the request first.
    final class FakeTransport: TokenTransport {
        var script: [(AgentRequest) -> AgentReply] = []
        var sent: [AgentRequest] = []
        func send(_ request: AgentRequest) throws -> AgentReply {
            sent.append(request)
            guard !script.isEmpty else { throw TokenTransportError.closed }
            return script.removeFirst()(request)
        }
    }

    private func reader(handle: String = "r0", card: String? = "c0") -> ReaderState {
        ReaderState(handle: handle, name: "rd", hasCard: true, card: card)
    }

    private func card(handle: String = "c0", reader: String = "r0") -> CardState {
        CardState(handle: handle, reader: reader, caps: [], preAuth: .none)
    }

    @Test("resolves the lone carded reader, then signs raw")
    func signResolvesLoneReaderThenSignsRaw() throws {
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .rawSignature(sig: Data([0x99])) },
        ]
        let sig = try TokenOpEngine(transport: t).sign(certId: "certX", digestInfo: Data([0x31]))
        #expect(sig == Data([0x99]))
        guard case .pkSignRaw(let r, let c, _, _) = t.sent[1] else {
            Issue.record("expected a pkSignRaw request, got \(t.sent[1])")
            return
        }
        #expect(r == "r0")
        #expect(c == "certX")
    }

    @Test("no carded reader maps to tokenNotFound")
    func noCardMapsToTokenNotFound() {
        let t = FakeTransport()
        t.script = [{ _ in .state(readers: [], cards: []) }]
        #expect(throws: TokenOpError.mapped(.tokenNotFound)) {
            _ = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]))
        }
    }

    @Test("a stale session triggers a login and one retry")
    func userNotLoggedInTriggersLoginAndRetry() throws {
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .err(ErrInfo(code: .name(.userNotLoggedIn))) },
            { _ in .ack },
            { _ in .rawSignature(sig: Data([0x77])) },
        ]
        let sig = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]))
        #expect(sig == Data([0x77]))
        #expect(t.sent.contains { if case .pkLogin = $0 { return true } else { return false } })
    }

    /// The first signature of every token session has no lease, so the PIN
    /// prompt is raised by the retry after the login, not by the first
    /// request. The retry's error reply must therefore be read through the
    /// same mapping as the first one: a cancel or a wrong PIN on it is the
    /// person's answer, not a device failure.
    private func retryFails(with name: SyncError) -> FakeTransport {
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .err(ErrInfo(code: .name(.userNotLoggedIn))) },
            { _ in .ack },
            { _ in .err(ErrInfo(code: .name(name))) },
        ]
        return t
    }

    @Test("a prompt dismissed on the retry maps to canceledByUser")
    func retryCancelledMapsToCanceledByUser() {
        let t = retryFails(with: .cancelled)
        #expect(throws: TokenOpError.mapped(.canceledByUser)) {
            _ = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]))
        }
        #expect(t.script.isEmpty)
    }

    @Test("a wrong PIN on the retry maps to authenticationFailed")
    func retryAuthFailedMapsToAuthenticationFailed() {
        let t = retryFails(with: .authFailed)
        #expect(throws: TokenOpError.mapped(.authenticationFailed)) {
            _ = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]))
        }
        #expect(t.script.isEmpty)
    }

    @Test("a rate-limited retry maps as a rate-limited first request does")
    func retryRateLimitedMapsLikeFirstRequest() {
        let t = retryFails(with: .rateLimited)
        #expect(throws: TokenOpError.mapped(.communicationError)) {
            _ = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]))
        }
        #expect(t.script.isEmpty)
    }

    @Test("a missing key on the retry maps to objectNotFound")
    func retryKeyNotFoundMapsToObjectNotFound() {
        let t = retryFails(with: .keyNotFound)
        #expect(throws: TokenOpError.mapped(.objectNotFound)) {
            _ = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]))
        }
        #expect(t.script.isEmpty)
    }

    @Test("a rate-limited reply maps to communicationError")
    func rateLimitedMapsToCommunicationError() {
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .err(ErrInfo(code: .name(.rateLimited))) },
        ]
        #expect(throws: TokenOpError.mapped(.communicationError)) {
            _ = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]))
        }
    }

    /// The wire gained a name for a dismissed prompt so a cancel would stop
    /// arriving as a device failure. This is the assertion that keeps it that
    /// way: the engine is the only macOS path the token actually reaches, and
    /// before this it folded `Cancelled` into `.communicationError` through a
    /// `default:` arm that swallowed it silently.
    @Test("a dismissed prompt maps to canceledByUser, not to a communication failure")
    func cancelledMapsToCanceledByUser() {
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .err(ErrInfo(code: .name(.cancelled))) },
        ]
        #expect(throws: TokenOpError.mapped(.canceledByUser)) {
            _ = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]))
        }
        // Named against the answer it must NOT give, so a future refactor that
        // reunites the two arms fails here rather than only in the copy tests.
        #expect(TKErrorMapped.canceledByUser != TKErrorMapped.communicationError)
    }

    /// The agent enforces the card's per-operation consent rule itself, so the
    /// token never logs in ahead of a signature: a fresh login would cost the
    /// warm lease of a key the card does not mark, and a marked key is asked
    /// for anyway. A login happens only after the agent says the lease is gone.
    @Test("sign goes straight to the agent; no login ahead of it")
    func signDoesNotLogInFirst() throws {
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .rawSignature(sig: Data([0x55])) },
        ]
        let sig = try TokenOpEngine(transport: t).sign(certId: "certZ", digestInfo: Data([0]))
        #expect(sig == Data([0x55]))
        #expect(!t.sent.contains { if case .pkLogin = $0 { return true } else { return false } })
    }

    @Test("multiple carded readers resolve by probing getCertDer")
    func multiCardResolvesByCertDerProbe() throws {
        let t = FakeTransport()
        t.script = [
            { _ in
                .state(
                    readers: [reader(handle: "r0", card: "c0"), reader(handle: "r1", card: "c1")],
                    cards: [card(handle: "c0", reader: "r0"), card(handle: "c1", reader: "r1")])
            },
            { _ in .err(ErrInfo(code: .name(.unknownCard))) },
            { _ in .certDer(der: Data([0x01])) },
            { _ in .rawSignature(sig: Data([0x55])) },
        ]
        let sig = try TokenOpEngine(transport: t).sign(certId: "certY", digestInfo: Data([0x02]))
        #expect(sig == Data([0x55]))
        guard case .pkSignRaw(let r, _, _, _) = t.sent.last else {
            Issue.record("expected a pkSignRaw request, got \(String(describing: t.sent.last))")
            return
        }
        #expect(r == "r1")
    }

    @Test("an RSA signature asks for exactly rsa-pkcs")
    func rsaSignNamesItsMechanism() throws {
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .rawSignature(sig: Data([0x99])) },
        ]
        _ = try TokenOpEngine(transport: t).sign(certId: "certX", digestInfo: Data([0x31]))
        guard case .pkSignRaw(_, _, let mech, _) = t.sent[1] else { Issue.record("no pkSignRaw"); return }
        #expect(mech == .rsaPkcs)
    }

    @Test("an EC signature sends the digest as ecdsa and returns X9.62 DER")
    func ecdsaSignReturnsDer() throws {
        let key = P384.Signing.PrivateKey()
        let digest = Data(SHA384.hash(data: Data("interop".utf8)))
        let reference = try key.signature(for: SHA384.hash(data: Data("interop".utf8)))
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .rawSignature(sig: reference.rawRepresentation) },
        ]
        let der = try TokenOpEngine(transport: t).signEcdsa(certId: "lk", digest: digest, keySizeInBits: 384)
        #expect(der == reference.derRepresentation)
        guard case .pkSignRaw(_, _, let mech, let data) = t.sent[1] else { Issue.record("no pkSignRaw"); return }
        #expect(mech == .ecdsa)
        #expect(data == digest)
    }

    @Test("a digest of the wrong length never reaches the agent")
    func ecdsaRefusesAWrongDigestLength() {
        let t = FakeTransport()
        #expect(throws: TokenOpError.mapped(.badParameter)) {
            _ = try TokenOpEngine(transport: t).signEcdsa(certId: "lk", digest: Data(count: 20), keySizeInBits: 384)
        }
        #expect(t.sent.isEmpty)
    }

    @Test("r||s with a short r converts on every curve")
    func ecdsaDerKeepsAShortR() throws {
        for (bits, width) in [(256, 32), (384, 48), (521, 66)] {
            var raw = Data(count: 2 * width)
            raw[width - 1] = 0x01            // r = 1: every byte but the last is a leading zero
            raw[2 * width - 1] = 0x02        // s = 2
            let der = try TokenOpEngine.ecdsaDer(fromRaw: raw, keySizeInBits: bits)
            #expect(der == Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]), "curve \(bits)")
        }
    }

    @Test("InvalidRequest from the agent is a bad parameter, not a device failure")
    func invalidRequestMapsToBadParameter() {
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .err(ErrInfo(code: .name(.invalidRequest))) },
        ]
        #expect(throws: TokenOpError.mapped(.badParameter)) {
            _ = try TokenOpEngine(transport: t).signEcdsa(certId: "lk", digest: Data(count: 48), keySizeInBits: 384)
        }
    }
}

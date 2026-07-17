// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
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
        let sig = try TokenOpEngine(transport: t).sign(certId: "certX", digestInfo: Data([0x31]), requireFreshAuth: false)
        #expect(sig == Data([0x99]))
        guard case .pkSignRaw(let r, let c, _) = t.sent[1] else {
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
            _ = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]), requireFreshAuth: false)
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
        let sig = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]), requireFreshAuth: false)
        #expect(sig == Data([0x77]))
        #expect(t.sent.contains { if case .pkLogin = $0 { return true } else { return false } })
    }

    @Test("a rate-limited reply maps to communicationError")
    func rateLimitedMapsToCommunicationError() {
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .err(ErrInfo(code: .name(.rateLimited))) },
        ]
        #expect(throws: TokenOpError.mapped(.communicationError)) {
            _ = try TokenOpEngine(transport: t).sign(certId: "x", digestInfo: Data([0]), requireFreshAuth: false)
        }
    }

    @Test("requireFreshAuth logs in before signing, every time")
    func requireFreshAuthLogsInBeforeSigning() throws {
        let t = FakeTransport()
        t.script = [
            { _ in .state(readers: [reader()], cards: [card()]) },
            { _ in .ack },
            { _ in .rawSignature(sig: Data([0x55])) },
        ]
        let sig = try TokenOpEngine(transport: t).sign(certId: "certZ", digestInfo: Data([0]), requireFreshAuth: true)
        #expect(sig == Data([0x55]))
        let loginIndex = t.sent.firstIndex { if case .pkLogin = $0 { return true } else { return false } }
        let signIndex = t.sent.firstIndex { if case .pkSignRaw = $0 { return true } else { return false } }
        let li = try #require(loginIndex)
        let si = try #require(signIndex)
        #expect(li < si)
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
        let sig = try TokenOpEngine(transport: t).sign(certId: "certY", digestInfo: Data([0x02]), requireFreshAuth: false)
        #expect(sig == Data([0x55]))
        guard case .pkSignRaw(let r, _, _) = t.sent.last else {
            Issue.record("expected a pkSignRaw request, got \(String(describing: t.sent.last))")
            return
        }
        #expect(r == "r1")
    }
}

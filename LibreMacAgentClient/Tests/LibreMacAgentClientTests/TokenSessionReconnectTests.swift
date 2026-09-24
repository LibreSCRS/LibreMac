// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
@testable import LibreMacAgentClient

/// ctkd keeps a `TKTokenSession` alive across agent-side closes, so the
/// session's connection must be rebuilt rather than failing every later
/// operation. These drive `ReconnectingTokenEngine` — the CTK-free unit the
/// session delegates to — over real sockets, with the mock agent closing its
/// end the way the agent does.
@Suite("TokenSessionReconnect")
struct TokenSessionReconnectTests {

    /// Counts the connections the unit asks for and wires each to `server`.
    final class Connector: @unchecked Sendable {
        let server: MockAgentServer
        let deadline: TimeInterval
        private(set) var made = 0
        var fail = false
        init(server: MockAgentServer, deadline: TimeInterval = 5) {
            self.server = server
            self.deadline = deadline
        }
        func connect() throws -> TokenTransport {
            made += 1
            if fail { throw TokenTransportError.connectFailed }
            return TokenAgentClient(connectedFd: server.connectedFd(), ioTimeout: deadline)
        }
    }

    private static let state = AgentReply.state(
        readers: [ReaderState(handle: "r0", name: "rd", hasCard: true, card: "c0")],
        cards: [CardState(handle: "c0", reader: "r0", caps: [], preAuth: .none)])

    /// Answers the whole sign sequence. The server closes its end after
    /// replying to `dropAfter`, or instead of replying to `dropInsteadOf`.
    private static func script(_ server: MockAgentServer, dropAfter: String? = nil,
                               dropInsteadOf: String? = nil) {
        server.onRequest = { [unowned server] req, tag in
            if tag == dropInsteadOf {
                server.dropRawConnection()
                return
            }
            switch tag {
            case "GetState": server.sendReplyRaw(state, req: req)
            case "Pkcs11.Login": server.sendReplyRaw(.ack, req: req)
            case "Pkcs11.SignRaw": server.sendReplyRaw(.rawSignature(sig: Data([0x5A])), req: req)
            default: break
            }
            if tag == dropAfter { server.dropRawConnection() }
        }
    }

    private func sign(_ unit: ReconnectingTokenEngine) throws -> Data {
        try unit.withEngine {
            try $0.sign(certId: "cert", digestInfo: Data([0x30]), requireFreshAuth: true)
        }
    }

    @Test("a connection the agent closed under a live session is rebuilt and the next sign succeeds")
    func tokenSessionReconnectsAfterAgentClose() throws {
        let server = MockAgentServer()
        let connector = Connector(server: server)
        let unit = ReconnectingTokenEngine(connect: connector.connect)

        Self.script(server, dropAfter: "Pkcs11.SignRaw")
        #expect(try sign(unit) == Data([0x5A]))
        #expect(connector.made == 1)

        Self.script(server)
        #expect(try sign(unit) == Data([0x5A]))
        #expect(connector.made == 2)
        #expect(server.count(of: "Pkcs11.SignRaw") == 2)
    }

    @Test("a second consecutive close surfaces communicationError instead of retrying again")
    func tokenSessionReconnectGivesUpAfterOneRetry() throws {
        let server = MockAgentServer()
        let connector = Connector(server: server)
        let unit = ReconnectingTokenEngine(connect: connector.connect)

        Self.script(server, dropInsteadOf: "GetState")
        #expect(throws: TokenOpError.mapped(.communicationError)) { _ = try sign(unit) }
        #expect(connector.made == 2)
        #expect(server.count(of: "GetState") == 2)

        // Giving up must not leave the dead connection cached: once the agent
        // answers again, the next operation connects afresh and succeeds.
        Self.script(server)
        #expect(try sign(unit) == Data([0x5A]))
        #expect(connector.made == 3)
    }

    @Test("a failed reconnect surfaces communicationError")
    func tokenSessionReconnectFailsWhenTheAgentIsGone() throws {
        let server = MockAgentServer()
        let connector = Connector(server: server)
        let unit = ReconnectingTokenEngine(connect: connector.connect)

        Self.script(server, dropAfter: "Pkcs11.SignRaw")
        #expect(try sign(unit) == Data([0x5A]))
        connector.fail = true
        #expect(throws: TokenOpError.mapped(.communicationError)) { _ = try sign(unit) }
        #expect(connector.made == 2)
    }

    /// The agent runs a delivered `SignRaw` to completion whether or not the
    /// connection that asked is still there, and that call is what raises the
    /// PIN prompt. Replaying it would prompt the person a second time and put
    /// a second signature on the card.
    @Test("a sign the agent received is never replayed on a fresh connection")
    func tokenSessionReconnectNeverReplaysADeliveredSign() throws {
        let server = MockAgentServer()
        let connector = Connector(server: server)
        let unit = ReconnectingTokenEngine(connect: connector.connect)

        Self.script(server, dropInsteadOf: "Pkcs11.SignRaw")
        #expect(throws: TokenOpError.mapped(.communicationError)) { _ = try sign(unit) }
        #expect(connector.made == 1)
        #expect(server.count(of: "Pkcs11.SignRaw") == 1)

        // The dead connection is still discarded: the next call reconnects.
        Self.script(server)
        #expect(try sign(unit) == Data([0x5A]))
        #expect(connector.made == 2)
    }

    /// A hung agent costs one reply deadline, not two: a new connection to the
    /// same process would only wait out the deadline again.
    @Test("an agent that accepts and never answers fails after one deadline, without reconnecting")
    func tokenSessionReconnectDoesNotReplayATimeout() throws {
        let server = MockAgentServer() // no script: requests are read, never answered
        let deadline: TimeInterval = 0.3
        let connector = Connector(server: server, deadline: deadline)
        let unit = ReconnectingTokenEngine(connect: connector.connect)

        let start = Date()
        #expect(throws: TokenOpError.mapped(.communicationError)) { _ = try sign(unit) }
        let elapsed = Date().timeIntervalSince(start)
        #expect(connector.made == 1)
        #expect(server.count(of: "GetState") == 1)
        #expect(elapsed < 2 * deadline)
    }

    /// Scripted transport for the case a socket cannot stage on demand: a
    /// request that never left this process, after one that did.
    final class FakeTransport: TokenTransport {
        var script: [(AgentRequest) throws -> AgentReply]
        init(_ script: [(AgentRequest) throws -> AgentReply]) { self.script = script }
        /// Past its script the fake behaves like a connection the peer has
        /// closed, so a unit that reuses it fails an assertion, not the process.
        func send(_ request: AgentRequest) throws -> AgentReply {
            guard !script.isEmpty else { throw TokenTransportError.closed }
            return try script.removeFirst()(request)
        }
    }

    @Test("an undelivered sign is not replayed once a login already reached the agent")
    func tokenSessionReconnectKeepsADeliveredLoginFromBeingRepeated() throws {
        var made = 0
        let unit = ReconnectingTokenEngine(connect: {
            made += 1
            return FakeTransport([
                { _ in Self.state },
                { _ in .ack },
                { _ in throw TokenTransportError.notDelivered },
            ])
        })
        #expect(throws: TokenOpError.mapped(.communicationError)) { _ = try sign(unit) }
        #expect(made == 1)
    }

    /// The engine probes readers with `try? GetCertDer`, so a connection that
    /// dies mid-probe surfaces as tokenNotFound. The connection must still be
    /// seen as failed, or the dead one stays cached for the next operation.
    @Test("a connection that died under a swallowed probe is rebuilt, not reported as a missing token")
    func tokenSessionReconnectSeesAFailureTheEngineSwallowed() throws {
        let twoCarded = AgentReply.state(
            readers: [ReaderState(handle: "r0", name: "a", hasCard: true, card: "c0"),
                      ReaderState(handle: "r1", name: "b", hasCard: true, card: "c1")],
            cards: [CardState(handle: "c0", reader: "r0", caps: [], preAuth: .none),
                    CardState(handle: "c1", reader: "r1", caps: [], preAuth: .none)])
        var made = 0
        let unit = ReconnectingTokenEngine(connect: {
            made += 1
            if made == 1 {
                return FakeTransport([
                    { _ in twoCarded },
                    { _ in throw TokenTransportError.closed },
                    { _ in throw TokenTransportError.notDelivered },
                ])
            }
            return FakeTransport([
                { _ in twoCarded },
                { _ in .certDer(der: Data([0x01])) },
                { _ in .ack },
                { _ in .rawSignature(sig: Data([0x44])) },
            ])
        })
        #expect(try sign(unit) == Data([0x44]))
        #expect(made == 2)
    }

    @Test("a request that never reached the agent is retried on a fresh connection")
    func tokenSessionReconnectRetriesAnUndeliveredRead() throws {
        var made = 0
        let unit = ReconnectingTokenEngine(connect: {
            made += 1
            if made == 1 {
                return FakeTransport([{ _ in throw TokenTransportError.notDelivered }])
            }
            return FakeTransport([
                { _ in Self.state },
                { _ in .ack },
                { _ in .rawSignature(sig: Data([0x33])) },
            ])
        })
        #expect(try sign(unit) == Data([0x33]))
        #expect(made == 2)
    }
}

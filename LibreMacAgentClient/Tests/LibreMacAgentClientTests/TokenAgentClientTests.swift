// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
@testable import LibreMacAgentClient

@Suite("TokenAgentClient")
struct TokenAgentClientTests {

    @Test("send returns the correlated reply and skips interleaved events")
    func sendReturnsCorrelatedReplyAndSkipsInterleavedEvents() throws {
        let server = MockAgentServer()
        server.onRequest = { req, tag in
            if tag == "Pkcs11.PublicKey" {
                server.sendEventRaw(.cardRemoved(handle: "reader/0")) // noise before the reply
                server.sendReplyRaw(.publicKey(kty: "RSA", n: Data([0xAA]), e: Data([0x01, 0x00, 0x01])), req: req)
            }
        }

        let client = TokenAgentClient(connectedFd: server.connectedFd())
        let reply = try client.send(.pkPublicKey(reader: "reader/0", cert: "certid"))

        guard case .publicKey(let kty, let n, let e) = reply else {
            Issue.record("expected .publicKey, got \(reply)")
            return
        }
        #expect(kty == "RSA")
        #expect(n == Data([0xAA]))
        #expect(e == Data([0x01, 0x00, 0x01]))
    }

    @Test("a peer that never replies surfaces ioFailed instead of hanging forever")
    func silentPeerSurfacesIoFailed() {
        let server = MockAgentServer() // no onRequest script: requests are read but never answered
        let client = TokenAgentClient(connectedFd: server.connectedFd(), ioTimeout: 0.2)
        #expect(throws: TokenTransportError.ioFailed) {
            _ = try client.send(.getState)
        }
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
import Testing
import Foundation
@testable import LibreMacAgentClient

struct Pkcs11WireTests {
    @Test func pkSignRawEncodesExactlyTheWireKeys() throws {
        let body = AgentRequest.pkSignRaw(reader: "reader/0", cert: "certid", data: Data([0xDE, 0xAD])).encode(req: 18)
        let m = try CBORValue.decode(body)                      // public decoder
        guard case .map(let pairs) = m else {
            #expect(Bool(false), "not a map")
            return
        }
        let keys = Set(pairs.map { String(decoding: $0.0, as: UTF8.self) })
        #expect(keys == ["t", "reader", "cert", "data", "req"])
    }

    @Test func rawSignatureReplyDecodes() throws {
        let body = CBORValue.map([
            (Data("t".utf8), .text("Reply")), (Data("req".utf8), .int(7)),
            (Data("sig".utf8), .bytes(Data([0x01, 0x02]))),
        ]).encode()
        let env = try AgentMessages.decodeReply(body)
        #expect(env.req == 7)
        guard case .rawSignature(let sig) = env.reply else {
            #expect(Bool(false), "wrong arm")
            return
        }
        #expect(sig == Data([0x01, 0x02]))
    }

    @Test func publicKeyReplyDecodesRSA() throws {
        let body = CBORValue.map([
            (Data("t".utf8), .text("Reply")), (Data("req".utf8), .int(3)),
            (Data("kty".utf8), .text("RSA")), (Data("n".utf8), .bytes(Data([0xAA]))),
            (Data("e".utf8), .bytes(Data([0x01, 0x00, 0x01]))),
        ]).encode()
        let env = try AgentMessages.decodeReply(body)
        guard case .publicKey(let kty, let n, let e) = env.reply else {
            #expect(Bool(false), "wrong arm")
            return
        }
        #expect(kty == "RSA")
        #expect(n == Data([0xAA]))
        #expect(e == Data([0x01, 0x00, 0x01]))
    }

    // Swift-side stability guard: the encoder must keep producing these exact bytes.
    // Cross-impl byte-exactness vs the C++ agent is covered by the live smoke test
    // and the agent's own wire-contract guard; do NOT edit LibreDarwin to make a fixture.
    @Test func pkSignRawByteStability() {
        let body = AgentRequest.pkSignRaw(reader: "r", cert: "c", data: Data([0x00])).encode(req: 1)
        // Captured from the first passing run of this test.
        let golden = Data([
            0xA5, 0x61, 0x74, 0x6E, 0x50, 0x6B, 0x63, 0x73, 0x31, 0x31, 0x2E, 0x53, 0x69, 0x67, 0x6E, 0x52, 0x61,
            0x77, 0x63, 0x72, 0x65, 0x71, 0x01, 0x64, 0x63, 0x65, 0x72, 0x74, 0x61, 0x63, 0x64, 0x64, 0x61, 0x74,
            0x61, 0x41, 0x00, 0x66, 0x72, 0x65, 0x61, 0x64, 0x65, 0x72, 0x61, 0x72,
        ])
        #expect(body == golden)
    }

    // Bounded decode: an over-cap declared frame length must be rejected, not allocated.
    @Test func frameHeaderRejectsOverCapLength() {
        #expect(throws: FrameError.oversize) {
            try Frame.encodeHeader(bodyLength: kMaxFrameBytes + 1, fdCount: 0)
        }
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
import Testing
import Foundation
@testable import LibreMacAgentClient

struct Pkcs11WireTests {
    @Test func pkSignRawEncodesExactlyTheWireKeys() throws {
        let body = AgentRequest.pkSignRaw(
            reader: "reader/0", cert: "certid", mech: .ecdsa, data: Data([0xDE, 0xAD])
        ).encode(req: 18)
        let m = try CBORValue.decode(body)                      // public decoder
        guard case .map(let pairs) = m else {
            #expect(Bool(false), "not a map")
            return
        }
        let keys = Set(pairs.map { String(decoding: $0.0, as: UTF8.self) })
        #expect(keys == ["t", "reader", "cert", "mech", "data", "req"])
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
        guard case .publicKey(.rsa(let n, let e)) = env.reply else {
            #expect(Bool(false), "wrong arm")
            return
        }
        #expect(n == Data([0xAA]))
        #expect(e == Data([0x01, 0x00, 0x01]))
    }

    @Test func publicKeyReplyDecodesEC() throws {
        let x = Data(repeating: 0x33, count: 48)
        let y = Data(repeating: 0x44, count: 48)
        let body = CBORValue.map([
            (Data("t".utf8), .text("Reply")), (Data("req".utf8), .int(4)),
            (Data("kty".utf8), .text("EC")), (Data("crv".utf8), .text("P-384")),
            (Data("x".utf8), .bytes(x)), (Data("y".utf8), .bytes(y)),
        ]).encode()
        let env = try AgentMessages.decodeReply(body)
        #expect(env.req == 4)
        #expect(env.reply == .publicKey(.ec(crv: "P-384", x: x, y: y)))
    }

    private func ecPublicKeyBody(crv: String, x: Int, y: Int) -> Data {
        CBORValue.map([
            (Data("t".utf8), .text("Reply")), (Data("req".utf8), .int(4)),
            (Data("kty".utf8), .text("EC")), (Data("crv".utf8), .text(crv)),
            (Data("x".utf8), .bytes(Data(repeating: 0x33, count: x))),
            (Data("y".utf8), .bytes(Data(repeating: 0x44, count: y))),
        ]).encode()
    }

    @Test("an EC public key decodes on every curve at exactly its field width",
          arguments: [("P-256", 32), ("P-384", 48), ("P-521", 66)])
    func publicKeyReplyDecodesEveryCurve(crv: String, width: Int) throws {
        let env = try AgentMessages.decodeReply(ecPublicKeyBody(crv: crv, x: width, y: width))
        #expect(env.reply == .publicKey(.ec(crv: crv, x: Data(repeating: 0x33, count: width),
                                             y: Data(repeating: 0x44, count: width))))
    }

    // The same rule as the C++ codec: a key the client cannot place on one of
    // the three curves is a malformed reply, not a key handed on.
    @Test("an EC public key on another curve or at another width is a decode error",
          arguments: [
              ("P-192", 48, 48, "crv"),     // a curve no card key is on
              ("p-384", 48, 48, "crv"),     // the name is exact, not case-folded
              ("P-384", 47, 48, "x"),       // x one byte short
              ("P-384", 48, 49, "y"),       // y one byte long
              ("P-521", 65, 65, "x"),       // P-521 coordinates are 66 bytes
              ("P-256", 48, 48, "x"),       // a P-384 point labelled P-256
          ])
    func publicKeyReplyOffCurveIsRejected(crv: String, x: Int, y: Int, field: String) {
        #expect(throws: MessageError.wrongType(field)) {
            _ = try AgentMessages.decodeReply(ecPublicKeyBody(crv: crv, x: x, y: y))
        }
    }

    // Swift-side stability guard: the encoder must keep producing these exact bytes.
    // Cross-impl byte-exactness vs the C++ agent is covered by the live smoke test
    // and the agent's own wire-contract guard; do NOT edit LibreDarwin to make a fixture.
    @Test func pkSignRawByteStability() {
        let body = AgentRequest.pkSignRaw(reader: "r", cert: "c", mech: .rsaPkcs, data: Data([0x00])).encode(req: 1)
        // Captured from the first passing run of this test.
        let golden = Data([
            0xA6, 0x61, 0x74, 0x6E, 0x50, 0x6B, 0x63, 0x73, 0x31, 0x31, 0x2E, 0x53, 0x69, 0x67, 0x6E, 0x52, 0x61,
            0x77, 0x63, 0x72, 0x65, 0x71, 0x01, 0x64, 0x63, 0x65, 0x72, 0x74, 0x61, 0x63, 0x64, 0x64, 0x61, 0x74,
            0x61, 0x41, 0x00, 0x64, 0x6D, 0x65, 0x63, 0x68, 0x68, 0x72, 0x73, 0x61, 0x2D, 0x70, 0x6B, 0x63, 0x73,
            0x66, 0x72, 0x65, 0x61, 0x64, 0x65, 0x72, 0x61, 0x72,
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

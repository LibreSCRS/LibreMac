// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
import CryptoTokenKit
import LibreMacAgentClient
import Security

final class TokenSession: TKTokenSession, TKTokenSessionDelegate {
    // One agent connection per session, opened lazily on the first delegate
    // call rather than at init: eager connection at init would either block the
    // session's creation on the socket round trip or, if pre-created with a
    // placeholder fd, silently wrap a broken connection that only fails later at
    // an unrelated call site. ctkd keeps this session alive across agent
    // restarts, so a connection the agent closed is rebuilt once per operation
    // (see `ReconnectingTokenEngine` for when replaying is safe); a failure that
    // cannot be recovered surfaces as `TKError.communicationError` from the
    // delegate call that needed it. The connection is closed via
    // `TokenAgentClient.deinit` when it fails or when the session deallocates.
    private let agent = ReconnectingTokenEngine(connect: { try TokenAgentClient() })

    private static let ecdsaAlgorithms: [SecKeyAlgorithm] = [
        .ecdsaSignatureDigestX962,
        .ecdsaSignatureDigestX962SHA256,
        .ecdsaSignatureDigestX962SHA384,
        .ecdsaSignatureDigestX962SHA512,
    ]

    override init(token: TKToken) {
        super.init(token: token)
        self.delegate = self
    }

    // The published key, for its family and size: the host registered it from
    // the certificate.
    private func key(for keyObjectID: TKToken.ObjectID) -> TKTokenKeychainKey? {
        try? token.keychainContents?.key(forObjectID: keyObjectID)
    }

    private static func isEc(_ key: TKTokenKeychainKey) -> Bool {
        key.keyType == kSecAttrKeyTypeECSECPrimeRandom as String
    }

    // What the agent can do with the card's key: RSA PKCS#1 v1.5 over a
    // DigestInfo, ECDSA over a digest.
    func tokenSession(_ session: TKTokenSession, supports operation: TKTokenOperation,
                       keyObjectID: TKToken.ObjectID, algorithm: TKTokenKeyAlgorithm) -> Bool {
        guard let key = key(for: keyObjectID) else { return false }
        switch operation {
        case .signData:
            if Self.isEc(key) {
                return Self.ecdsaAlgorithms.contains { algorithm.isAlgorithm($0) }
            }
            return key.keyType == kSecAttrKeyTypeRSA as String
                && algorithm.isAlgorithm(.rsaSignatureDigestPKCS1v15Raw)
        default:
            return false
        }
    }

    func tokenSession(_ session: TKTokenSession, sign dataToSign: Data,
                       keyObjectID: TKToken.ObjectID, algorithm: TKTokenKeyAlgorithm) throws -> Data {
        let certId = try objectIDString(keyObjectID)
        guard let key = key(for: keyObjectID) else { throw NSError(tkError: .objectNotFound) }
        do {
            // The card decides: the agent asks for the PIN before every
            // signature with a key the card marks for consent per operation,
            // and within its lease for any other key. The token adds no login
            // of its own, so what the user sees follows the card.
            return try agent.withEngine { engine in
                if Self.isEc(key) {
                    return try engine.signEcdsa(certId: certId, digest: dataToSign, keySizeInBits: key.keySizeInBits)
                }
                return try engine.sign(certId: certId, digestInfo: dataToSign)
            }
        } catch let TokenOpError.mapped(code) {
            throw NSError(tkError: code)
        }
    }

    // The auth operation needs nothing from the constraint or the key: the
    // agent enforces the card's PIN rule at the operation itself.
    func tokenSession(_ session: TKTokenSession, beginAuthFor operation: TKTokenOperation,
                       constraint: Any) throws -> TKTokenAuthOperation {
        TokenAuthOperation()
    }
}

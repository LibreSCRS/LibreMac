// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
import CryptoTokenKit
import LibreMacAgentClient

final class TokenSession: TKTokenSession, TKTokenSessionDelegate {
    // One agent connection per session, opened lazily on the first delegate
    // call rather than at init: eager connection at init would either block the
    // session's creation on the socket round trip or, if pre-created with a
    // placeholder fd, silently wrap a broken connection that only fails later at
    // an unrelated call site. ctkd keeps this session alive across agent
    // restarts, so a connection the agent closed is rebuilt once per operation
    // (see `ReconnectingTokenEngine` for when replaying is safe); a failure that
    // cannot be recovered surfaces as `TKError.communicationError` from the
    // delegate call that needed it (`signData` / `beginAuthFor`). The connection
    // is closed via `TokenAgentClient.deinit` when it fails or when the session
    // itself deallocates.
    private let agent = ReconnectingTokenEngine(connect: { try TokenAgentClient() })

    override init(token: TKToken) {
        super.init(token: token)
        self.delegate = self
    }

    // Advertise only RSA sign — exactly what the agent can service over the card.
    func tokenSession(_ session: TKTokenSession, supports operation: TKTokenOperation,
                       keyObjectID: TKToken.ObjectID, algorithm: TKTokenKeyAlgorithm) -> Bool {
        operation == .signData && algorithm.isAlgorithm(.rsaSignatureDigestPKCS1v15Raw)
    }

    func tokenSession(_ session: TKTokenSession, sign dataToSign: Data,
                       keyObjectID: TKToken.ObjectID, algorithm: TKTokenKeyAlgorithm) throws -> Data {
        let certId = try objectIDString(keyObjectID)
        do {
            // Every key requires a fresh login for every signature, mirroring
            // the client PKCS#11 proxy's always-authenticate advertisement:
            // the extension only ever sees an opaque certId and has no
            // reliable way to tell a non-repudiation key from an
            // authentication key, so a uniform per-signature prompt is the
            // only safe default.
            return try agent.withEngine {
                try $0.sign(certId: certId, digestInfo: dataToSign, requireFreshAuth: true)
            }
        } catch let TokenOpError.mapped(code) {
            throw NSError(tkError: code)
        }
    }

    // We do NOT trust `constraint` to carry the objectID — the framework hands it
    // back as an opaque authID. The real objectID is read from the token's
    // keychain key. TKTokenKeychainContents exposes only `items` (no `keys`
    // accessor), so filter it to the key item.
    func tokenSession(_ session: TKTokenSession, beginAuthFor operation: TKTokenOperation,
                       constraint: Any) throws -> TKTokenAuthOperation {
        guard let key = self.token.keychainContents?.items
            .compactMap({ $0 as? TKTokenKeychainKey }).first
        else {
            throw NSError(tkError: .objectNotFound)
        }
        let certId = try objectIDString(key.objectID)
        return TokenAuthOperation(agent: agent, certId: certId)
    }
}

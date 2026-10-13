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
    // delegate call that needed it (`signData`). The connection
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
            // The card decides: the agent asks for the PIN before every
            // signature with a key the card marks for consent per operation,
            // and within its lease for any other key. The token adds no login
            // of its own, so what the user sees follows the card.
            return try agent.withEngine {
                try $0.sign(certId: certId, digestInfo: dataToSign)
            }
        } catch let TokenOpError.mapped(code) {
            throw NSError(tkError: code)
        }
    }

    // The auth operation needs nothing from the constraint or the key: the
    // agent enforces the card's PIN rule at the signature itself.
    func tokenSession(_ session: TKTokenSession, beginAuthFor operation: TKTokenOperation,
                       constraint: Any) throws -> TKTokenAuthOperation {
        TokenAuthOperation()
    }
}

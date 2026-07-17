// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
import CryptoTokenKit
import LibreMacAgentClient

// Protected-auth operation: the secret NEVER reaches the extension. finish() (the
// Swift bridge of -finishWithError:) asks the agent to prompt+verify; no PIN is
// passed. The certId is threaded in by the session's beginAuthFor (read from the
// token's keychain key), NOT from the constraint.
final class TokenAuthOperation: TKTokenAuthOperation {
    private let engine: TokenOpEngine
    private let certId: String

    init(engine: TokenOpEngine, certId: String) {
        self.engine = engine
        self.certId = certId
        super.init()
    }

    // TKTokenAuthOperation adopts NSSecureCoding; a subclass with a custom
    // designated init must supply the required NSCoding initializer. This op is
    // never archived/unarchived by the system (it is created fresh in
    // beginAuthFor and finished immediately), so a trapping stub is correct.
    required init?(coder: NSCoder) {
        fatalError("TokenAuthOperation is not NSCoding-decodable")
    }

    override func finish() throws {
        do {
            try engine.login(certId: certId)
        } catch let TokenOpError.mapped(code) {
            throw NSError(tkError: code)
        }
    }
}

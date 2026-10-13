// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
import CryptoTokenKit
import LibreMacAgentClient

// Auth operation for the signData constraint: it succeeds without touching the
// agent. The secret NEVER reaches the extension, and the agent asks for the PIN
// itself when a signature needs one (every signature for a key the card marks,
// once per lease otherwise). A login here would only reset the lease's verified
// state and cost an unmarked key a prompt it does not need.
final class TokenAuthOperation: TKTokenAuthOperation {
    override init() {
        super.init()
    }

    // TKTokenAuthOperation adopts NSSecureCoding; a subclass with a custom
    // designated init must supply the required NSCoding initializer. This op is
    // never archived/unarchived by the system (it is created fresh in
    // beginAuthFor and finished immediately), so a trapping stub is correct.
    required init?(coder: NSCoder) {
        fatalError("TokenAuthOperation is not NSCoding-decodable")
    }

    override func finish() throws {}
}

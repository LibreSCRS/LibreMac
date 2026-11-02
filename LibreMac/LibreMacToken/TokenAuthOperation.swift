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

    // TKTokenAuthOperation adopts NSSecureCoding because CryptoTokenKit may
    // carry an operation between processes. This one has no state of its own,
    // so decoding it is decoding the superclass; a trap here would end the
    // extension on any signature where the system does decode it.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func finish() throws {}
}

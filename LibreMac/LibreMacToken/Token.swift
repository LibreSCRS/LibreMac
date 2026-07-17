// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
import CryptoTokenKit

final class Token: TKToken, TKTokenDelegate {
    override init(tokenDriver: TKTokenDriver, instanceID: TKToken.InstanceID) {
        super.init(tokenDriver: tokenDriver, instanceID: instanceID)
        self.delegate = self
    }

    func createSession(_ token: TKToken) throws -> TKTokenSession {
        TokenSession(token: self)
    }
}

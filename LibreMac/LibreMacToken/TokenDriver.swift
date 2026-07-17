// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
import CryptoTokenKit

// SHAPE (b): a plain TKTokenDriver that is NEVER handed a TKSmartCard. The host app
// publishes the identity via TKTokenDriverConfiguration; ctkd loads this driver only
// to service sign/auth, which is forwarded to the agent. The @objc name must match
// Info.plist's com.apple.ctk.driver-class / NSExtensionPrincipalClass. The
// subclass-IS-its-own-delegate pattern requires self.delegate = self in the ctor,
// else the tokenFor(configuration:) hook never fires.
@objc(LibreMacTokenDriver)
final class TokenDriver: TKTokenDriver, TKTokenDriverDelegate {
    override init() {
        super.init()
        self.delegate = self
    }

    func tokenDriver(_ driver: TKTokenDriver,
                      tokenFor configuration: TKToken.Configuration) throws -> TKToken {
        Token(tokenDriver: driver, instanceID: configuration.instanceID)
    }
}

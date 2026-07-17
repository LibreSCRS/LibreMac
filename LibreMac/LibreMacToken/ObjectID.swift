// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
import CryptoTokenKit
import Foundation
import LibreMacAgentClient

enum TokenError: Error { case unmarshalableObjectID }

/// A TKToken.ObjectID is opaque `Any` (String- or Data/NSData-backed). Return the
/// registered String label: accept a real String, else UTF-8-decode Data, else fail.
/// NEVER String(describing:) — that hex-stringifies NSData.
func objectIDString(_ oid: TKToken.ObjectID) throws -> String {
    if let s = oid as? String { return s }
    if let d = oid as? Data, let s = String(data: d, encoding: .utf8) { return s }
    throw TokenError.unmarshalableObjectID
}

extension NSError {
    convenience init(tkError code: TKErrorMapped) {
        let c: TKError.Code
        switch code {
        case .tokenNotFound: c = .tokenNotFound
        case .authenticationFailed: c = .authenticationFailed
        case .objectNotFound: c = .objectNotFound
        case .authenticationNeeded: c = .authenticationNeeded
        case .communicationError: c = .communicationError
        case .notImplemented: c = .notImplemented
        }
        self.init(domain: TKErrorDomain, code: c.rawValue, userInfo: nil)
    }
}

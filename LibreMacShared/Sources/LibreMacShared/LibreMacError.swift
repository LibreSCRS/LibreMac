// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Top-level error type for LibreMac. Conforms to `LocalizedError` so SwiftUI
/// `.alert(isPresented:error:)` and similar surfaces can render a localised
/// message without bespoke plumbing.
public enum LibreMacError: Error, Sendable, Equatable, LocalizedError {
    case bridgeUnavailable(diagnostic: String)
    case readerUnavailable(LocalizedText)
    case noCardPresent(LocalizedText)
    case communicationError(LocalizedText, diagnostic: String?)
    case parseError(LocalizedText, diagnostic: String?)
    case authenticationFailed(LocalizedText, retriesLeft: Int?)
    case pinIncorrect(retriesLeft: Int?)
    case pinBlocked
    case userCancelled
    case unsupportedCard(LocalizedText)
    case signingEngineError(LocalizedText, diagnostic: String?)
    case unknown(LocalizedText, diagnostic: String?)

    public var errorDescription: String? {
        switch self {
        case .bridgeUnavailable(let diag):
            return "LibreMac bridge unavailable: \(diag)"
        case .readerUnavailable(let t),
             .noCardPresent(let t),
             .unsupportedCard(let t):
            return t.resolve()
        case .communicationError(let t, _),
             .parseError(let t, _),
             .signingEngineError(let t, _),
             .unknown(let t, _):
            return t.resolve()
        case .authenticationFailed(let t, let n):
            if let n {
                return "\(t.resolve()) (\(n) tries left)"
            }
            return t.resolve()
        case .pinIncorrect(let n):
            if let n {
                return "PIN incorrect (\(n) tries left)"
            }
            return "PIN incorrect"
        case .pinBlocked:
            return "PIN is blocked"
        case .userCancelled:
            return "Operation cancelled"
        }
    }
}

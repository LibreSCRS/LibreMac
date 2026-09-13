// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// CTK-free operation logic for the token extension: reader resolution,
/// login/sign sequencing, and agent-error -> `TKErrorMapped` mapping.
///
/// Sequences requests over a `TokenTransport` (one instance per
/// `TKTokenSession`, thread-confined to ctkd's calling thread — see
/// `TokenTransport`'s own doc comment). Keeping this logic here, decoupled
/// from CryptoTokenKit, makes it unit-testable without a `TKTokenSession`.
public struct TokenOpEngine {
    private let transport: TokenTransport

    public init(transport: TokenTransport) {
        self.transport = transport
    }

    /// Resolves the reader handle holding `certId`'s card. A single
    /// carded reader is returned without a certificate probe; with more
    /// than one, each carded reader is probed via `getCertDer` in order
    /// and the first to answer with a `certDer` (rather than an error)
    /// is chosen.
    public func resolveReader(certId: String) throws -> String {
        guard case .state(let readers, _) = try transport.send(.getState) else {
            throw TokenOpError.mapped(.communicationError)
        }
        let withCard = readers.filter { $0.hasCard }
        if withCard.count == 1 { return withCard[0].handle }
        if withCard.isEmpty { throw TokenOpError.mapped(.tokenNotFound) }
        for r in withCard {
            if case .certDer = (try? transport.send(.getCertDer(reader: r.handle, cert: certId))) {
                return r.handle
            }
        }
        throw TokenOpError.mapped(.tokenNotFound)
    }

    /// Performs a fresh `Pkcs11.Login` on the reader holding `certId`'s
    /// card. Used by `beginAuth`, ahead of a `sign` that requires fresh
    /// consent.
    public func login(certId: String) throws {
        let reader = try resolveReader(certId: certId)
        if case .err(let info) = try transport.send(.pkLogin(reader: reader)) {
            throw TokenOpError.mapped(map(info))
        }
    }

    /// Signs `digestInfo` under `certId`. When `requireFreshAuth` is
    /// false and the agent reports the session as not logged in, retries
    /// once after a login rather than surfacing the stale-session error.
    public func sign(certId: String, digestInfo: Data, requireFreshAuth: Bool) throws -> Data {
        let reader = try resolveReader(certId: certId)
        if requireFreshAuth {
            if case .err(let info) = try transport.send(.pkLogin(reader: reader)) {
                throw TokenOpError.mapped(map(info))
            }
        }
        switch try transport.send(.pkSignRaw(reader: reader, cert: certId, data: digestInfo)) {
        case .rawSignature(let sig):
            return sig
        case .err(let info):
            if !requireFreshAuth, syncError(info) == .userNotLoggedIn {
                if case .err(let loginInfo) = try transport.send(.pkLogin(reader: reader)) {
                    throw TokenOpError.mapped(map(loginInfo))
                }
                guard case .rawSignature(let sig) =
                    try transport.send(.pkSignRaw(reader: reader, cert: certId, data: digestInfo))
                else {
                    throw TokenOpError.mapped(.communicationError)
                }
                return sig
            }
            throw TokenOpError.mapped(map(info))
        default:
            throw TokenOpError.mapped(.communicationError)
        }
    }

    /// Fetches the RSA public key (modulus, exponent) for `certId`.
    public func publicKey(certId: String) throws -> (n: Data, e: Data) {
        let reader = try resolveReader(certId: certId)
        guard case .publicKey(_, let n, let e) = try transport.send(.pkPublicKey(reader: reader, cert: certId)) else {
            throw TokenOpError.mapped(.objectNotFound)
        }
        return (n, e)
    }

    private func syncError(_ info: ErrInfo) -> SyncError? {
        if case .name(let se) = info.code { return se }
        return nil
    }

    private func map(_ info: ErrInfo) -> TKErrorMapped {
        // A reply that carries a numeric code instead of a name has no token
        // to read; that is the only nil this guard absorbs. Everything below
        // is exhaustive over `SyncError` (no `default`) so an appended wire
        // name forces a mapping decision here rather than being folded into
        // the communication answer unnoticed: a gate that only reads the
        // names an enum carries cannot see a case the copy tables downstream
        // do not yet handle.
        guard let name = syncError(info) else { return .communicationError }
        switch name {
        case .unknownCard: return .tokenNotFound
        case .keyNotFound: return .objectNotFound
        case .authFailed, .notAuthorized: return .authenticationFailed
        case .userNotLoggedIn: return .authenticationNeeded
        case .notSupported: return .notImplemented
        case .cancelled:
            // The person dismissed the prompt. CryptoTokenKit has a code for
            // exactly this. Answering `communicationError` instead reports a
            // device failure for what was an answer, and what a caller then
            // does with a token it believes broken is its own choice, not one
            // this process can take back; `canceledByUser` says only that this
            // attempt was declined and leaves the second try open.
            return .canceledByUser
        case .rateLimited, .communicationError, .unknownConfigKey, .readOnlyConfig,
             .invalidConfigValue, .unsupportedProtocol, .unsupportedOnThisCard,
             .unsupportedSignatureParameter, .inputTooLarge, .unknownCredential,
             .invalidRequest, .noResult, .masterListReplayed:
            return .communicationError
        }
    }
}

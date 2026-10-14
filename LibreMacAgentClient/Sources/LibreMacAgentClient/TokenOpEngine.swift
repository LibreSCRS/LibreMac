// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import CryptoKit
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

    /// Signs `digestInfo` (a complete PKCS#1 v1.5 DigestInfo) under `certId`
    /// with the card's RSA key. When the agent reports the session as not
    /// logged in (no lease, or the lease lapsed), logs in and retries once. No
    /// login is made ahead of the signature: the agent asks for the PIN itself
    /// whenever the card's rule for the key requires it.
    public func sign(certId: String, digestInfo: Data) throws -> Data {
        try signRaw(certId: certId, mech: .rsaPkcs, input: digestInfo)
    }

    /// Signs `digest` (SHA-256, -384 or -512: 32, 48 or 64 bytes) under
    /// `certId` with the card's EC key and returns the X9.62 DER signature
    /// Keychain expects. A digest of any other length is refused here, before
    /// the agent; the agent answers r||s, converted for the curve
    /// `keySizeInBits` names.
    public func signEcdsa(certId: String, digest: Data, keySizeInBits: Int) throws -> Data {
        guard [32, 48, 64].contains(digest.count) else { throw TokenOpError.mapped(.badParameter) }
        let raw = try signRaw(certId: certId, mech: .ecdsa, input: digest)
        return try Self.ecdsaDer(fromRaw: raw, keySizeInBits: keySizeInBits)
    }

    /// r||s (each half ceil(bits/8) bytes) -> X9.62 DER, for P-256, P-384 or P-521.
    public static func ecdsaDer(fromRaw raw: Data, keySizeInBits: Int) throws -> Data {
        do {
            switch keySizeInBits {
            case 256: return try P256.Signing.ECDSASignature(rawRepresentation: raw).derRepresentation
            case 384: return try P384.Signing.ECDSASignature(rawRepresentation: raw).derRepresentation
            case 521: return try P521.Signing.ECDSASignature(rawRepresentation: raw).derRepresentation
            default: throw TokenOpError.mapped(.notImplemented)
            }
        } catch let error as TokenOpError {
            throw error
        } catch {
            // The agent's r||s does not have the curve's width.
            throw TokenOpError.mapped(.communicationError)
        }
    }

    private func signRaw(certId: String, mech: PkSignMech, input: Data) throws -> Data {
        let reader = try resolveReader(certId: certId)
        let request = AgentRequest.pkSignRaw(reader: reader, cert: certId, mech: mech, data: input)
        switch try transport.send(request) {
        case .rawSignature(let sig):
            return sig
        case .err(let info):
            if syncError(info) == .userNotLoggedIn {
                if case .err(let loginInfo) = try transport.send(.pkLogin(reader: reader)) {
                    throw TokenOpError.mapped(map(loginInfo))
                }
                // The retry is where a session's first signature raises the
                // PIN prompt, so its error reply is mapped like the first one:
                // a cancel or a wrong PIN is an answer, not a device failure.
                return try signReply(transport.send(request))
            }
            throw TokenOpError.mapped(map(info))
        default:
            throw TokenOpError.mapped(.communicationError)
        }
    }

    private func signReply(_ reply: AgentReply) throws -> Data {
        switch reply {
        case .rawSignature(let sig): return sig
        case .err(let info): throw TokenOpError.mapped(map(info))
        default: throw TokenOpError.mapped(.communicationError)
        }
    }

    /// Fetches the public key for `certId`: RSA or EC. An EC key is returned
    /// only when it is the curve `keySizeInBits` names (the size the
    /// certificate gives) and each coordinate is exactly that curve's width;
    /// anything else is refused as `communicationError`, never handed on.
    public func publicKey(certId: String, keySizeInBits: Int) throws -> PublicKey {
        let reader = try resolveReader(certId: certId)
        guard case .publicKey(let key) = try transport.send(.pkPublicKey(reader: reader, cert: certId)) else {
            throw TokenOpError.mapped(.objectNotFound)
        }
        if case .ec(let crv, let x, let y) = key {
            let curves = [256: "P-256", 384: "P-384", 521: "P-521"]
            let width = (keySizeInBits + 7) / 8
            guard curves[keySizeInBits] == crv, x.count == width, y.count == width else {
                throw TokenOpError.mapped(.communicationError)
            }
        }
        return key
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
        case .invalidRequest:
            // The agent refused the input before any prompt.
            return .badParameter
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
             .noResult, .masterListReplayed:
            return .communicationError
        }
    }
}

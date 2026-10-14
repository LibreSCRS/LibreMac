// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import CryptoKit
import Foundation
import Security

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

    /// The signatures the token offers for a published key (`keyType` is the
    /// key's `kSecAttrKeyType`): ECDSA over a digest for an EC key, PKCS#1
    /// v1.5 over a DigestInfo for an RSA key, and none for a key the agent
    /// does not sign with -- an EC key published for key agreement only.
    public static func signAlgorithms(keyType: String, canSign: Bool) -> [SecKeyAlgorithm] {
        guard canSign else { return [] }
        if keyType == kSecAttrKeyTypeECSECPrimeRandom as String {
            return [.ecdsaSignatureDigestX962, .ecdsaSignatureDigestX962SHA256,
                    .ecdsaSignatureDigestX962SHA384, .ecdsaSignatureDigestX962SHA512]
        }
        if keyType == kSecAttrKeyTypeRSA as String { return [.rsaSignatureDigestPKCS1v15Raw] }
        return []
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
        return try consentedRequest(request, reader: reader) {
            if case .rawSignature(let sig) = $0 { return sig }
            return nil
        }
    }

    /// The key exchanges the token offers: raw ECDH, whose result is Z itself.
    /// The cofactor variant gives the same Z on the NIST curves (cofactor 1).
    /// A KDF variant never reaches the token: Security runs the KDF in process
    /// over the raw result.
    public static let keyExchangeAlgorithms: [SecKeyAlgorithm] = [
        .ecdhKeyExchangeStandard,
        .ecdhKeyExchangeCofactor,
    ]

    /// ECDH with the card's EC key against `peerPoint` (X9.63 uncompressed,
    /// 04||X||Y): the raw shared secret Z, exactly the field width of the
    /// curve `keySizeInBits` names (anything else is refused as
    /// `communicationError`). The agent is asked first whether it serves key
    /// agreement at all -- one without the "ec-keys" feature drops the
    /// connection on the request.
    public func performKeyExchange(certId: String, peerPoint: Data, keySizeInBits: Int) throws -> Data {
        let hello = try transport.send(.hello(proto: UInt64(kProtocolVersion), client: nil))
        guard case .helloAck(_, let features) = hello, features.contains("ec-keys") else {
            throw TokenOpError.mapped(.notImplemented)
        }
        let reader = try resolveReader(certId: certId)
        let z = try consentedRequest(.pkDerive(reader: reader, cert: certId, data: peerPoint), reader: reader) {
            if case .derivedSecret(let z) = $0 { return z }
            return nil
        }
        guard z.count == (keySizeInBits + 7) / 8 else { throw TokenOpError.mapped(.communicationError) }
        return z
    }

    // A request the agent may answer "not logged in": log in and retry once.
    // No login is made ahead of it -- the agent asks for the PIN itself
    // whenever the card's rule for the key requires it. The retry is where a
    // session's first operation raises the PIN prompt, so its error reply is
    // mapped like the first one: a cancel or a wrong PIN is an answer, not a
    // device failure.
    private func consentedRequest(_ request: AgentRequest, reader: String,
                                  answer: (AgentReply) -> Data?) throws -> Data {
        let first = try transport.send(request)
        if let value = answer(first) { return value }
        guard case .err(let info) = first else { throw TokenOpError.mapped(.communicationError) }
        guard syncError(info) == .userNotLoggedIn else { throw TokenOpError.mapped(map(info)) }
        if case .err(let loginInfo) = try transport.send(.pkLogin(reader: reader)) {
            throw TokenOpError.mapped(map(loginInfo))
        }
        let retry = try transport.send(request)
        if let value = answer(retry) { return value }
        if case .err(let retryInfo) = retry { throw TokenOpError.mapped(map(retryInfo)) }
        throw TokenOpError.mapped(.communicationError)
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

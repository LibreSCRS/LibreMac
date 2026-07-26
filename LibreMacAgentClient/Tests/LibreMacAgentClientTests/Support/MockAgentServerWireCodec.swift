// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
@testable import LibreMacAgentClient

// Server-side (agent -> client) wire encode + (client -> agent) wire decode.
// `Messages.swift` in the package only builds the CLIENT's outbound
// requests and parses the CLIENT's inbound replies/events — the mirror
// image (decode a request, build a reply/event) has no production use, so
// it lives here as test support instead of widening the package's public
// surface. Field names/shapes are kept in lockstep with `Messages.swift`'s
// `decodeReply`/`decodeEvent` — this is the one file that must be updated
// alongside it.

struct DecodedRequest: Sendable, Equatable {
    let req: UInt64
    let request: AgentRequest
}

enum MockWireError: Error, Sendable {
    case malformed
}

// MARK: - Request decode (client -> agent)

func decodeAgentRequest(_ body: Data) throws -> DecodedRequest {
    let value = try CBORValue.decode(body)
    guard case .map(let pairs) = value else { throw MockWireError.malformed }

    guard let t = mwText(pairs, "t"), let req = mwUInt(pairs, "req") else { throw MockWireError.malformed }

    let request: AgentRequest
    switch t {
    case "Hello":
        request = .hello(proto: mwUInt(pairs, "proto") ?? 0, client: mwText(pairs, "client"))
    case "GetState":
        request = .getState
    case "ReadIdentity":
        request = .readIdentity(card: mwText(pairs, "card") ?? "")
    case "GetPhoto":
        request = .getPhoto(card: mwText(pairs, "card") ?? "")
    case "ReadCertificates":
        request = .readCertificates(card: mwText(pairs, "card") ?? "")
    case "Sign":
        request = .sign(
            card: mwText(pairs, "card") ?? "",
            cert: mwText(pairs, "cert") ?? "",
            inFd: mwUInt(pairs, "in") ?? 0,
            opts: decodeSignOptions(mwGet(pairs, "opts")))
    case "GetCertDer":
        request = .getCertDer(reader: mwText(pairs, "reader") ?? "", cert: mwText(pairs, "cert") ?? "")
    case "GetConfig":
        request = .getConfig
    case "SetConfig":
        request = .setConfig(key: mwText(pairs, "key") ?? "", value: mwGet(pairs, "value") ?? .null)
    case "ResetConfig":
        request = .resetConfig(key: mwText(pairs, "key") ?? "")
    case "CancelOp":
        request = .cancelOp(op: mwUInt(pairs, "op") ?? 0)
    case "GetSignResult":
        request = .getSignResult(op: mwUInt(pairs, "op") ?? 0)
    case "Pkcs11.Login":
        request = .pkLogin(reader: mwText(pairs, "reader") ?? "")
    case "Pkcs11.Logout":
        request = .pkLogout(reader: mwText(pairs, "reader") ?? "")
    case "Pkcs11.PublicKey":
        request = .pkPublicKey(reader: mwText(pairs, "reader") ?? "", cert: mwText(pairs, "cert") ?? "")
    case "Pkcs11.SignRaw":
        request = .pkSignRaw(
            reader: mwText(pairs, "reader") ?? "",
            cert: mwText(pairs, "cert") ?? "",
            data: mwBytes(pairs, "data") ?? Data())
    case "Pkcs11.Decrypt":
        request = .pkDecrypt(
            reader: mwText(pairs, "reader") ?? "",
            cert: mwText(pairs, "cert") ?? "",
            data: mwBytes(pairs, "data") ?? Data())
    case "ListCredentials":
        request = .listCredentials(card: mwText(pairs, "card") ?? "")
    case "ManagePin":
        // The client's encoder omits `activateKey` for every verb but
        // `.activatePin`; absent flattens back onto `false`. An
        // unrecognized verb token fails closed like an unknown `t`.
        guard let verb = CredentialVerb(rawValue: mwText(pairs, "verb") ?? "") else {
            throw MockWireError.malformed
        }
        request = .managePin(
            card: mwText(pairs, "card") ?? "",
            pinId: mwText(pairs, "pinId") ?? "",
            verb: verb,
            activateKey: mwBool(pairs, "activateKey") ?? false)
    case "ActivateSigningKey":
        request = .activateSigningKey(card: mwText(pairs, "card") ?? "")
    default:
        throw MockWireError.malformed
    }
    return DecodedRequest(req: req, request: request)
}

private func decodeVisualSignatureOptions(_ value: CBORValue?) -> VisualSignatureOptions? {
    guard case .map(let pairs)? = value else { return nil }
    return VisualSignatureOptions(
        page: mwUInt(pairs, "page") ?? 0,
        x: mwDouble(pairs, "x") ?? 0,
        y: mwDouble(pairs, "y") ?? 0,
        width: mwDouble(pairs, "width") ?? 0,
        height: mwDouble(pairs, "height") ?? 0,
        text: mwText(pairs, "text") ?? "")
}

private func decodeSignOptions(_ value: CBORValue?) -> SignOptions {
    guard case .map(let pairs)? = value else { return SignOptions(format: "", level: "", packaging: "") }
    return SignOptions(
        format: mwText(pairs, "format") ?? "",
        level: mwText(pairs, "level") ?? "",
        packaging: mwText(pairs, "packaging") ?? "",
        allowExpired: mwBool(pairs, "allowExpired"),
        displayName: mwText(pairs, "displayName"),
        reason: mwText(pairs, "reason"),
        location: mwText(pairs, "location"),
        tsaUrl: mwText(pairs, "tsaUrl"),
        visualSignature: decodeVisualSignatureOptions(mwGet(pairs, "visualSignature")))
}

/// The wire `"t"` tag for a decoded request — used by `MockAgentServer` to
/// keep a per-shape call count (e.g. "did exactly one `GetSignResult`
/// recovery call happen").
func requestTag(_ request: AgentRequest) -> String {
    switch request {
    case .hello: return "Hello"
    case .getState: return "GetState"
    case .readIdentity: return "ReadIdentity"
    case .getPhoto: return "GetPhoto"
    case .readCertificates: return "ReadCertificates"
    case .sign: return "Sign"
    case .getCertDer: return "GetCertDer"
    case .getConfig: return "GetConfig"
    case .setConfig: return "SetConfig"
    case .resetConfig: return "ResetConfig"
    case .cancelOp: return "CancelOp"
    case .getSignResult: return "GetSignResult"
    case .pkLogin: return "Pkcs11.Login"
    case .pkLogout: return "Pkcs11.Logout"
    case .pkPublicKey: return "Pkcs11.PublicKey"
    case .pkSignRaw: return "Pkcs11.SignRaw"
    case .pkDecrypt: return "Pkcs11.Decrypt"
    case .listCredentials: return "ListCredentials"
    case .managePin: return "ManagePin"
    case .activateSigningKey: return "ActivateSigningKey"
    }
}

// MARK: - Reply encode (agent -> client)

func encodeReply(_ reply: AgentReply, req: UInt64) -> Data {
    var pairs: [(String, CBORValue)] = [("t", .text("Reply")), ("req", .uint(req))]
    switch reply {
    case .helloAck(let agentVer, let features):
        pairs.append(("kind", .text("HelloAck")))
        pairs.append(("agentVer", .text(agentVer)))
        pairs.append(("features", .array(features.map { .text($0) })))
    case .opStarted(let op):
        pairs.append(("op", .uint(op)))
    case .state(let readers, let cards):
        pairs.append(("readers", .array(readers.map(encodeReaderState))))
        pairs.append(("cards", .array(cards.map(encodeCardState))))
    case .certList(let certs):
        pairs.append(("certs", .array(certs.map(encodeCertInfo))))
    case .certDer(let der):
        pairs.append(("der", .bytes(der)))
    case .publicKey(let kty, let n, let e):
        pairs.append(("kty", .text(kty)))
        pairs.append(("n", .bytes(n)))
        pairs.append(("e", .bytes(e)))
    case .rawSignature(let sig):
        pairs.append(("sig", .bytes(sig)))
    case .config(let entries):
        pairs.append(("entries", .map(entries.map { (Data($0.key.utf8), $0.value) })))
    case .ack:
        pairs.append(("ok", .bool(true)))
    case .signRecovery(let result):
        pairs.append(("result", encodeSignResult(result)))
    case .err(let info):
        pairs.append(("err", encodeErrInfo(info)))
    }
    return mwMap(pairs).encode()
}

// MARK: - Event encode (agent -> client, unsolicited)

func encodeEvent(_ event: AgentEvent) -> Data {
    var pairs: [(String, CBORValue)]
    switch event {
    case .readerAdded(let reader):
        pairs = [("t", .text("ReaderAdded")), ("reader", encodeReaderState(reader))]
    case .readerRemoved(let handle):
        pairs = [("t", .text("ReaderRemoved")), ("handle", .text(handle))]
    case .cardAdded(let card):
        pairs = [("t", .text("CardAdded")), ("card", encodeCardState(card))]
    case .cardRemoved(let handle):
        pairs = [("t", .text("CardRemoved")), ("handle", .text(handle))]
    case .propertyChanged(let handle, let iface, let props):
        pairs = [
            ("t", .text("PropertyChanged")), ("handle", .text(handle)), ("iface", .text(iface)),
            ("props", .map(props.map { (Data($0.key.utf8), $0.value) })),
        ]
    case .configChanged(let key):
        pairs = [("t", .text("ConfigChanged")), ("key", .text(key))]
    case .opProgress(let op, let phase, let progress, let indeterminate, let watchdogSecs):
        pairs = [("t", .text("OpProgress")), ("op", .uint(op)), ("phase", .uint(UInt64(phase.wireValue)))]
        if let progress { pairs.append(("progress", .double(progress))) }
        if let indeterminate { pairs.append(("indeterminate", .bool(indeterminate))) }
        if let watchdogSecs { pairs.append(("watchdogSecs", .uint(watchdogSecs))) }
    case .opResultReady(let op, let result):
        pairs = [("t", .text("OpResultReady")), ("op", .uint(op)), ("result", encodeOpResult(result))]
    case .opFinished(let op, let status, let code, let msgKey, let msgFallback):
        pairs = [
            ("t", .text("OpFinished")), ("op", .uint(op)), ("status", .uint(UInt64(status.wireValue))),
            ("code", .uint(UInt64(code.wireValue))), ("msgKey", .text(msgKey)), ("msgFallback", .text(msgFallback)),
        ]
    case .agentQuiesced(let reason):
        pairs = [("t", .text("AgentQuiesced")), ("reason", .uint(UInt64(reason.wireValue)))]
    }
    return mwMap(pairs).encode()
}

// MARK: - Shared sub-structure encoders

private func encodeReaderState(_ reader: ReaderState) -> CBORValue {
    var pairs: [(String, CBORValue)] = [
        ("handle", .text(reader.handle)), ("name", .text(reader.name)), ("hasCard", .bool(reader.hasCard)),
    ]
    if let card = reader.card {
        pairs.append(("card", .text(card)))
    }
    return mwMap(pairs)
}

private func encodeCardState(_ card: CardState) -> CBORValue {
    mwMap([
        ("handle", .text(card.handle)), ("reader", .text(card.reader)),
        ("caps", .uint(UInt64(card.caps.rawValue))), ("preAuth", .uint(UInt64(card.preAuth.wireValue))),
    ])
}

private func encodeCertInfo(_ info: CertificateInfo) -> CBORValue {
    mwMap([
        ("certId", .text(info.certId)),
        ("signingCapable", .bool(info.signingCapable)),
        ("fields", encodeCertFieldGroups(info.fields)),
        ("keyUsageBits", .uint(UInt64(info.keyUsageBits))),
        ("ekus", .array(info.ekus.map { .text($0) })),
        ("chainSubjectCns", .array(info.chainSubjectCns.map { .text($0) })),
        ("trustStatus", .uint(UInt64(info.trustStatus))),
    ])
}

private func encodeCertFieldGroups(_ groups: [String: [String: CertField]]) -> CBORValue {
    .map(
        groups.map { group, fields in
            (
                Data(group.utf8),
                .map(
                    fields.map { key, field in
                        (Data(key.utf8), .array([.text(field.labelKey), .text(field.labelFallback), .text(field.value)]))
                    })
            )
        })
}

private func encodeIdentityFieldGroups(_ groups: [String: [String: IdentityField]]) -> CBORValue {
    .map(
        groups.map { group, fields in
            (
                Data(group.utf8),
                .map(
                    fields.map { key, field in
                        let valueCbor: CBORValue
                        switch field.value {
                        case .text(let s): valueCbor = .text(s)
                        case .binary(let d): valueCbor = .bytes(d)
                        }
                        return (
                            Data(key.utf8),
                            .array([.text(field.labelKey), .text(field.labelFallback), .text(field.type), valueCbor])
                        )
                    })
            )
        })
}

private func encodeSignResult(_ result: SignResult) -> CBORValue {
    mwMap([
        ("kind", .text("Sign")),
        ("artifact", .uint(result.artifact)),
        (
            "meta",
            mwMap([
                ("format", .text(result.meta.format)), ("level", .text(result.meta.level)),
                ("tsaUsed", .bool(result.meta.tsaUsed)), ("chainComplete", .bool(result.meta.chainComplete)),
            ])
        ),
    ])
}

private func encodeCredResult(_ result: CredentialResult) -> CBORValue {
    var pairs: [(String, CBORValue)] = [("outcome", .text(result.outcome.rawValue))]
    if let retriesLeft = result.retriesLeft {
        pairs.append(("retriesLeft", .uint(UInt64(retriesLeft))))
    }
    pairs.append(("blocked", .bool(result.blocked)))
    if let pinActivated = result.pinActivated {
        pairs.append(("pinActivated", .bool(pinActivated)))
    }
    if let keyActivated = result.keyActivated {
        pairs.append(("keyActivated", .bool(keyActivated)))
    }
    return mwMap(pairs)
}

private func encodeCredRecord(_ record: CredentialRecord) -> CBORValue {
    var pairs: [(String, CBORValue)] = [
        ("id", .text(record.id)),
        ("label", .text(record.label)),
        ("kind", .text(record.kind.rawValue)),
        ("state", .text(record.state.rawValue)),
    ]
    if let v = record.retriesLeft { pairs.append(("retriesLeft", .uint(UInt64(v)))) }
    if let v = record.retriesMax { pairs.append(("retriesMax", .uint(UInt64(v)))) }
    if let v = record.usesLeft { pairs.append(("usesLeft", .uint(UInt64(v)))) }
    if let v = record.usesMax { pairs.append(("usesMax", .uint(UInt64(v)))) }
    if let v = record.unblocksLeft { pairs.append(("unblocksLeft", .uint(UInt64(v)))) }
    if let v = record.minLength { pairs.append(("minLength", .uint(UInt64(v)))) }
    if let v = record.maxLength { pairs.append(("maxLength", .uint(UInt64(v)))) }
    pairs.append(contentsOf: [
        ("canChange", .bool(record.canChange)),
        ("unblockable", .bool(record.unblockable)),
        ("unblockStyle", .text(record.unblockStyle.rawValue)),
        ("activatable", .bool(record.activatable)),
        ("keyActivationPending", .bool(record.keyActivationPending)),
        ("keyActivatable", .bool(record.keyActivatable)),
        ("recovery", .text(record.recovery.rawValue)),
        ("probeSafe", .bool(record.probeSafe)),
    ])
    if let v = record.blockedGuidanceKey { pairs.append(("blockedGuidanceKey", .text(v))) }
    if let v = record.blockedGuidanceFallback { pairs.append(("blockedGuidanceFallback", .text(v))) }
    if let v = record.keyActivationGuidanceKey { pairs.append(("keyActivationGuidanceKey", .text(v))) }
    if let v = record.keyActivationGuidanceFallback { pairs.append(("keyActivationGuidanceFallback", .text(v))) }
    return mwMap(pairs)
}

private func encodeOpResult(_ result: OpResult) -> CBORValue {
    switch result {
    case .identity(let r):
        return mwMap([("kind", .text("Identity")), ("fields", encodeIdentityFieldGroups(r.fields))])
    case .photo(let r):
        return mwMap([
            ("kind", .text("Photo")),
            ("photos", .array(r.photos.map { mwMap([("key", .text($0.key)), ("fd", .uint($0.fd))]) })),
        ])
    case .certificates(let certs):
        return mwMap([("kind", .text("Certificates")), ("certs", .array(certs.map(encodeCertInfo)))])
    case .sign(let result):
        return encodeSignResult(result)
    case .credentials(let payload):
        return mwMap([
            ("kind", .text("Credentials")),
            ("result", encodeCredResult(payload.result)),
            ("records", .array(payload.records.map(encodeCredRecord))),
        ])
    }
}

private func encodeErrInfo(_ info: ErrInfo) -> CBORValue {
    var pairs: [(String, CBORValue)] = []
    switch info.code {
    case .code(let code): pairs.append(("code", .uint(UInt64(code.wireValue))))
    case .name(let name): pairs.append(("name", .text(name.rawValue)))
    }
    if let msgKey = info.msgKey {
        pairs.append(("msgKey", .text(msgKey)))
    }
    if let msgFallback = info.msgFallback {
        pairs.append(("msgFallback", .text(msgFallback)))
    }
    return mwMap(pairs)
}

// MARK: - CBORValue helpers

private func mwMap(_ pairs: [(String, CBORValue)]) -> CBORValue {
    .map(pairs.map { (Data($0.0.utf8), $0.1) })
}

private func mwGet(_ pairs: [(Data, CBORValue)], _ key: String) -> CBORValue? {
    let keyData = Data(key.utf8)
    for (k, v) in pairs where k == keyData {
        return v
    }
    return nil
}

private func mwText(_ pairs: [(Data, CBORValue)], _ key: String) -> String? {
    if case .text(let s)? = mwGet(pairs, key) { return s }
    return nil
}

private func mwBool(_ pairs: [(Data, CBORValue)], _ key: String) -> Bool? {
    if case .bool(let b)? = mwGet(pairs, key) { return b }
    return nil
}

private func mwBytes(_ pairs: [(Data, CBORValue)], _ key: String) -> Data? {
    if case .bytes(let b)? = mwGet(pairs, key) { return b }
    return nil
}

private func mwUInt(_ pairs: [(Data, CBORValue)], _ key: String) -> UInt64? {
    switch mwGet(pairs, key) {
    case .uint(let u): return u
    case .int(let i) where i >= 0: return UInt64(i)
    default: return nil
    }
}

private func mwDouble(_ pairs: [(Data, CBORValue)], _ key: String) -> Double? {
    if case .double(let d)? = mwGet(pairs, key) { return d }
    return nil
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Typed (de)serialization over the `CBORValue` wire seam
/// (`CanonicalCBOR.swift`), mirroring the LibreDarwin agent's
/// `LibreSCRS::Darwin::wire` message layer (`Messages.h` / `Messages.cpp`)
/// and the reconciled CDDL contract (`agent/wire/librescrs-agent.cddl`).
///
/// The client is a socket CLIENT, the mirror image of the agent's SERVER
/// role: it BUILDS outbound requests (`AgentRequest.encode(req:)`, exactly
/// the wire-specified keys, no extras) and PARSES inbound replies/events
/// (`AgentMessages.decodeReply` / `.decodeEvent`), tolerating unknown map
/// keys on those inbound shapes (append-only evolution) while failing
/// closed on an unrecognized `t` discriminator (`.unknownMessage`).
///
/// Reply-arm discrimination: unlike requests (tagged by `t`) and events
/// (also tagged by `t`), every reply shares the literal `t: "Reply"` — the
/// CDDL disambiguates `reply-ok`'s nine arms structurally, "discriminated
/// by their own keys" (`librescrs-agent.cddl:91-93`). `decodeReply` mirrors
/// that: `err` first (exclusive with every success arm), then the
/// remaining arms by their distinguishing key(s), in the CDDL's declared
/// order.
///
/// Enum-VALUE tolerance (distinct from the map-KEY tolerance above): inside
/// an otherwise-recognized shape, a closed enum's unrecognized VALUE never
/// fails the frame either (`ClientCodec.h`'s tolerance table is the
/// normative policy this mirrors). Numeric wire enums (`ErrorCode`,
/// `OperationPhase`, `OperationStatus`, `QuiesceReason`, `PreReadAuth`) are
/// wire-frozen append-only, so a value past this build's last named one is
/// a FUTURE value, bounded only by the enum's OWN underlying-storage width
/// (mirroring `ClientCodec.cpp`'s per-enum `static_cast` guards): `phase`,
/// `status` and `code` are `uint32_t` on the wire and go through
/// `requireWireEnumValue32` below; `preAuth` and `reason` are `uint8_t` on
/// the wire and go through `requireWireEnumValue8`. Both helpers reject
/// only a value too wide for that width to represent losslessly —
/// genuinely malformed — and each enum's `init(wireValue:)` carries the
/// (width-bounded) survivor through as `.unknown(UInt32)`. TEXT-token enums
/// (`CredentialOutcome`, and `err-info`'s `SyncError` name arm) have no
/// width to bound against, so an unrecognized token DEGRADES AT DECODE
/// instead, to `.unspecified` / `.communicationError` respectively — see
/// `parseCredResult` and `parseErrInfo` below.

// MARK: - Errors

/// Message-layer decode failure. Distinct from `CBORError` (the byte-level
/// decode failure it wraps via `.notCanonicalCBOR`), mirroring the
/// LibreDarwin agent's `WireError` split for the client's inbound
/// (reply/event) parsing path.
public enum MessageError: Error, Sendable, Equatable {
    /// The frame body was not canonical CBOR (wraps the `CBORError`).
    case notCanonicalCBOR(CBORError)
    /// The top-level decoded item was not a CBOR map.
    case notAMap
    /// The `t` discriminator was not a known reply/event tag.
    case unknownMessage
    /// A required field was absent.
    case missingField(String)
    /// A field was present but had the wrong CBOR type (or an enum-valued
    /// field's raw value was out of range).
    case wrongType(String)
    /// A `Reply` map matched none of the known reply-arm key signatures.
    case unrecognizedShape
}

// MARK: - Error info (reply `err` arm)

/// The `err` arm of a reply: either the async numeric `ErrorCode` or a
/// named synchronous-method `SyncError` — never both. Mirrors
/// `LibreSCRS::Darwin::wire::ErrInfo` and CDDL `err-info`
/// (`librescrs-agent.cddl:97`).
public struct ErrInfo: Sendable, Equatable {
    public enum Code: Sendable, Equatable {
        case code(ErrorCode)
        case name(SyncError)
    }

    public let code: Code
    public let msgKey: String?
    public let msgFallback: String?

    public init(code: Code, msgKey: String? = nil, msgFallback: String? = nil) {
        self.code = code
        self.msgKey = msgKey
        self.msgFallback = msgFallback
    }
}

// MARK: - Op-result payloads (OpResultReady / SignRecovery)

/// The typed payload of an `OpResultReady` event, dispatched by the
/// `result.kind` wire tag. Mirrors `LibreSCRS::Darwin::wire::OpResult` and
/// CDDL `op-result` (`librescrs-agent.cddl:153`).
public enum OpResult: Sendable, Equatable {
    case identity(IdentityResult)
    case photo(PhotoResult)
    case certificates([CertificateInfo])
    case sign(SignResult)
    case credentials(CredentialsPayload)
}

// MARK: - Requests (client -> agent)

/// One client -> agent request body. Matches the agent's request-body wire
/// contract, including the `Pkcs11.*` family used by the CTK extension's
/// PKCS#11 seam.
public enum AgentRequest: Sendable, Equatable {
    case hello(proto: UInt64, client: String?)
    case getState
    case readIdentity(card: String)
    case getPhoto(card: String)
    case readCertificates(card: String)
    /// Lightweight token-info read (PKCS#15 TokenInfo or equivalent). Result
    /// rides the EXISTING op-result-ready kind "Identity" — a single "token"
    /// group (label/serial_number/manufacturer) — never a new result shape.
    /// Gated on the `"token-info"` HelloAck feature token, like the
    /// credentials family above.
    case readTokenInfo(card: String)
    case sign(card: String, cert: String, inFd: UInt64, opts: SignOptions)
    case getCertDer(reader: String, cert: String)
    case getConfig
    case setConfig(key: SettableConfigKey, value: CBORValue)
    /// `key` stays a raw wire token, not `SettableConfigKey`: `ResetConfig`
    /// addresses the WIDER CDDL `config-key` rule (`settable-config-key`
    /// plus the read-only keys `LastTsaUrl`/`TslCacheDir`/`AiaCacheDir`/
    /// `PluginDir`), and the contract-side vocabulary discovery that
    /// `SettableConfigKey` exists to support deliberately does not resolve
    /// that wider rule. Narrowing this to `SettableConfigKey` would make it
    /// impossible to reset a read-only key, which the wire allows.
    case resetConfig(key: String)
    case cancelOp(op: UInt64)
    case getSignResult(op: UInt64)
    case pkLogin(reader: String)
    case pkLogout(reader: String)
    case pkPublicKey(reader: String, cert: String)
    case pkSignRaw(reader: String, cert: String, data: Data)
    case pkDecrypt(reader: String, cert: String, data: Data)
    /// Credentials1 seam — gate all three on the `"credentials"` HelloAck
    /// feature token (`librescrs-agent.cddl:122-128`): an agent predating
    /// that contract fails an unknown request `t` closed and DROPS the
    /// connection, so skipping the gate costs the whole session.
    case listCredentials(card: String)
    /// `pinId` is a record id from the most recent listing of this card
    /// (this wire never carries a secret). `activateKey` crosses the wire
    /// only with verb `.activatePin` — see `encode(req:)`.
    case managePin(card: String, pinId: String, verb: CredentialVerb, activateKey: Bool)
    case activateSigningKey(card: String)
}

extension AgentRequest {

    /// The canonical encoded frame body for this request, addressed by
    /// `req` (the caller-assigned id echoed back on the matching reply).
    /// Emits exactly the wire-specified keys for this request's shape — no
    /// extras — mirroring the agent's request-body encoder.
    public func encode(req: UInt64) -> Data {
        var pairs: [(String, CBORValue)]
        switch self {
        case .hello(let proto, let client):
            pairs = [("t", .text("Hello")), ("proto", .int(Int64(proto)))]
            if let client {
                pairs.append(("client", .text(client)))
            }
        case .getState:
            pairs = [("t", .text("GetState"))]
        case .readIdentity(let card):
            pairs = [("t", .text("ReadIdentity")), ("card", .text(card))]
        case .getPhoto(let card):
            pairs = [("t", .text("GetPhoto")), ("card", .text(card))]
        case .readCertificates(let card):
            pairs = [("t", .text("ReadCertificates")), ("card", .text(card))]
        case .readTokenInfo(let card):
            pairs = [("t", .text("ReadTokenInfo")), ("card", .text(card))]
        case .sign(let card, let cert, let inFd, let opts):
            pairs = [
                ("t", .text("Sign")),
                ("card", .text(card)),
                ("cert", .text(cert)),
                ("in", .int(Int64(inFd))),
                ("opts", encodeSignOptions(opts)),
            ]
        case .getCertDer(let reader, let cert):
            pairs = [("t", .text("GetCertDer")), ("reader", .text(reader)), ("cert", .text(cert))]
        case .getConfig:
            pairs = [("t", .text("GetConfig"))]
        case .setConfig(let key, let value):
            pairs = [("t", .text("SetConfig")), ("key", .text(key.rawValue)), ("value", value)]
        case .resetConfig(let key):
            pairs = [("t", .text("ResetConfig")), ("key", .text(key))]
        case .cancelOp(let op):
            pairs = [("t", .text("CancelOp")), ("op", .int(Int64(op)))]
        case .getSignResult(let op):
            pairs = [("t", .text("GetSignResult")), ("op", .int(Int64(op)))]
        case .pkLogin(let reader):
            pairs = [("t", .text("Pkcs11.Login")), ("reader", .text(reader))]
        case .pkLogout(let reader):
            pairs = [("t", .text("Pkcs11.Logout")), ("reader", .text(reader))]
        case .pkPublicKey(let reader, let cert):
            pairs = [("t", .text("Pkcs11.PublicKey")), ("reader", .text(reader)), ("cert", .text(cert))]
        case .pkSignRaw(let reader, let cert, let data):
            pairs = [("t", .text("Pkcs11.SignRaw")), ("reader", .text(reader)),
                     ("cert", .text(cert)), ("data", .bytes(data))]
        case .pkDecrypt(let reader, let cert, let data):
            pairs = [("t", .text("Pkcs11.Decrypt")), ("reader", .text(reader)),
                     ("cert", .text(cert)), ("data", .bytes(data))]
        case .listCredentials(let card):
            pairs = [("t", .text("ListCredentials")), ("card", .text(card))]
        case .managePin(let card, let pinId, let verb, let activateKey):
            pairs = [
                ("t", .text("ManagePin")),
                ("card", .text(card)),
                ("pinId", .text(pinId)),
                ("verb", .text(verb.rawValue)),
            ]
            // `activateKey` is legal only with verb "activate_pin"
            // (InvalidRequest otherwise, `librescrs-agent.cddl:79-86`):
            // flatten the non-optional Bool onto the wire's optional key
            // by OMITTING it for every other verb, mirroring the peer
            // codec's `std::optional<bool>` encode.
            if verb == .activatePin {
                pairs.append(("activateKey", .bool(activateKey)))
            }
        case .activateSigningKey(let card):
            pairs = [("t", .text("ActivateSigningKey")), ("card", .text(card))]
        }
        pairs.append(("req", .int(Int64(req))))
        return cborMap(pairs).encode()
    }
}

private func encodeVisualSignatureOptions(_ v: VisualSignatureOptions) -> CBORValue {
    cborMap([
        ("page", .int(Int64(v.page))),
        ("x", .double(v.x)),
        ("y", .double(v.y)),
        ("width", .double(v.width)),
        ("height", .double(v.height)),
        ("text", .text(v.text)),
    ])
}

private func encodeSignOptions(_ o: SignOptions) -> CBORValue {
    var pairs: [(String, CBORValue)] = [
        ("format", .text(o.format.rawValue)),
        ("level", .text(o.level.rawValue)),
        ("packaging", .text(o.packaging.rawValue)),
    ]
    if let allowExpired = o.allowExpired {
        pairs.append(("allowExpired", .bool(allowExpired)))
    }
    if let displayName = o.displayName {
        pairs.append(("displayName", .text(displayName)))
    }
    if let reason = o.reason {
        pairs.append(("reason", .text(reason)))
    }
    if let location = o.location {
        pairs.append(("location", .text(location)))
    }
    if let tsaUrl = o.tsaUrl {
        pairs.append(("tsaUrl", .text(tsaUrl)))
    }
    if let visualSignature = o.visualSignature {
        pairs.append(("visualSignature", encodeVisualSignatureOptions(visualSignature)))
    }
    return cborMap(pairs)
}

private func cborMap(_ pairs: [(String, CBORValue)]) -> CBORValue {
    .map(pairs.map { (Data($0.0.utf8), $0.1) })
}

// MARK: - Replies (agent -> client)

/// One agent -> client reply arm. Mirrors the reply builders in
/// `LibreSCRS::Darwin::wire` and CDDL `reply-ok`
/// (`librescrs-agent.cddl:106-118`) plus the `err` arm
/// (`librescrs-agent.cddl:93,97`), including the `Pkcs11.*` surface's
/// `PublicKeyReply` / `RawSignatureReply` arms.
public enum AgentReply: Sendable, Equatable {
    case helloAck(agentVer: String, features: [String])
    case opStarted(op: UInt64)
    case state(readers: [ReaderState], cards: [CardState])
    case certList(certs: [CertificateInfo])
    case certDer(der: Data)
    case publicKey(kty: String, n: Data, e: Data)
    case rawSignature(sig: Data)
    case config(entries: [String: CBORValue])
    case ack
    case signRecovery(SignResult)
    case err(ErrInfo)
}

/// A decoded reply, correlated to its request by `req`. Mirrors the
/// `{t:"Reply", req, ...}` envelope (`librescrs-agent.cddl:93`).
public struct AgentReplyEnvelope: Sendable, Equatable {
    public let req: UInt64
    public let reply: AgentReply

    public init(req: UInt64, reply: AgentReply) {
        self.req = req
        self.reply = reply
    }
}

// MARK: - Events (agent -> client, unsolicited)

/// One unsolicited agent -> client event. Mirrors the event builders in
/// `LibreSCRS::Darwin::wire` and CDDL `event`
/// (`librescrs-agent.cddl:131-133`).
public enum AgentEvent: Sendable, Equatable {
    case readerAdded(ReaderState)
    case readerRemoved(handle: String)
    case cardAdded(CardState)
    case cardRemoved(handle: String)
    case propertyChanged(handle: String, iface: String, props: [String: CBORValue])
    case configChanged(key: String)
    case opProgress(op: UInt64, phase: OperationPhase, progress: Double?, indeterminate: Bool?, watchdogSecs: UInt64?)
    /// Fires BEFORE `opFinished` for the same `op` (the operation event
    /// ordering contract) — the distinct result-carrying event.
    case opResultReady(op: UInt64, result: OpResult)
    case opFinished(op: UInt64, status: OperationStatus, code: ErrorCode, msgKey: String, msgFallback: String)
    case agentQuiesced(reason: QuiesceReason)
}

// MARK: - Decode entry points

/// Namespace for the client's inbound (reply/event) parsers. Caseless by
/// design — there is no client-side state here, only pure decode
/// functions (mirrors `AgentTypes.swift`'s value-type style).
public enum AgentMessages {

    /// Decodes one `Reply` frame body. Unknown map keys are tolerated and
    /// ignored (append-only evolution); a `t` other than `"Reply"`, or
    /// a reply map matching none of the known arm signatures, fails
    /// closed.
    public static func decodeReply(_ body: Data) throws(MessageError) -> AgentReplyEnvelope {
        let decoded = try decodeCanonical(body)
        let m = try requireTopLevelMap(decoded)
        let tag = try requireText(m, "t")
        guard tag == "Reply" else { throw .unknownMessage }
        let req = try requireUInt64(m, "req")

        if let errRaw = mapGet(m, "err") {
            return AgentReplyEnvelope(req: req, reply: .err(try parseErrInfo(errRaw)))
        }
        if let kindRaw = mapGet(m, "kind"), case .text("HelloAck") = kindRaw {
            let agentVer = try requireText(m, "agentVer")
            let features = try requireTextArray(m, "features")
            return AgentReplyEnvelope(req: req, reply: .helloAck(agentVer: agentVer, features: features))
        }
        if mapGet(m, "readers") != nil || mapGet(m, "cards") != nil {
            let readersArr = try requireArray(m, "readers")
            let cardsArr = try requireArray(m, "cards")
            var readers: [ReaderState] = []
            for item in readersArr {
                readers.append(try parseReaderState(item))
            }
            var cards: [CardState] = []
            for item in cardsArr {
                cards.append(try parseCardState(item))
            }
            return AgentReplyEnvelope(req: req, reply: .state(readers: readers, cards: cards))
        }
        if let certsRaw = mapGet(m, "certs") {
            guard case .array(let certsArr) = certsRaw else { throw .wrongType("certs") }
            var certs: [CertificateInfo] = []
            for item in certsArr {
                certs.append(try parseCertInfo(item))
            }
            return AgentReplyEnvelope(req: req, reply: .certList(certs: certs))
        }
        if let derRaw = mapGet(m, "der") {
            guard case .bytes(let der) = derRaw else { throw .wrongType("der") }
            return AgentReplyEnvelope(req: req, reply: .certDer(der: der))
        }
        if let sigRaw = mapGet(m, "sig") {
            guard case .bytes(let sig) = sigRaw else { throw .wrongType("sig") }
            return AgentReplyEnvelope(req: req, reply: .rawSignature(sig: sig))
        }
        if let ktyRaw = mapGet(m, "kty") {
            guard case .text(let kty) = ktyRaw, kty == "RSA" else { throw .wrongType("kty") }
            guard case .bytes(let n)? = mapGet(m, "n") else { throw .missingField("n") }
            guard case .bytes(let e)? = mapGet(m, "e") else { throw .missingField("e") }
            return AgentReplyEnvelope(req: req, reply: .publicKey(kty: kty, n: n, e: e))
        }
        if let entriesRaw = mapGet(m, "entries") {
            let entriesMap = try requireMap(entriesRaw, field: "entries")
            var entries: [String: CBORValue] = [:]
            for (k, v) in entriesMap {
                entries[String(decoding: k, as: UTF8.self)] = v
            }
            return AgentReplyEnvelope(req: req, reply: .config(entries: entries))
        }
        if let okRaw = mapGet(m, "ok") {
            guard case .bool(true) = okRaw else { throw .wrongType("ok") }
            return AgentReplyEnvelope(req: req, reply: .ack)
        }
        if let resultRaw = mapGet(m, "result") {
            return AgentReplyEnvelope(req: req, reply: .signRecovery(try parseSignResult(resultRaw)))
        }
        if mapGet(m, "op") != nil {
            return AgentReplyEnvelope(req: req, reply: .opStarted(op: try requireUInt64(m, "op")))
        }
        throw .unrecognizedShape
    }

    /// Decodes one event frame body. Unknown map keys are tolerated and
    /// ignored (append-only evolution); an unrecognized `t` fails closed with
    /// `.unknownMessage`.
    public static func decodeEvent(_ body: Data) throws(MessageError) -> AgentEvent {
        let decoded = try decodeCanonical(body)
        let m = try requireTopLevelMap(decoded)
        let tag = try requireText(m, "t")

        switch tag {
        case "ReaderAdded":
            guard let readerRaw = mapGet(m, "reader") else { throw .missingField("reader") }
            return .readerAdded(try parseReaderState(readerRaw))
        case "ReaderRemoved":
            return .readerRemoved(handle: try requireText(m, "handle"))
        case "CardAdded":
            guard let cardRaw = mapGet(m, "card") else { throw .missingField("card") }
            return .cardAdded(try parseCardState(cardRaw))
        case "CardRemoved":
            return .cardRemoved(handle: try requireText(m, "handle"))
        case "PropertyChanged":
            let handle = try requireText(m, "handle")
            let iface = try requireText(m, "iface")
            guard let propsRaw = mapGet(m, "props") else { throw .missingField("props") }
            let propsMap = try requireMap(propsRaw, field: "props")
            var props: [String: CBORValue] = [:]
            for (k, v) in propsMap {
                props[String(decoding: k, as: UTF8.self)] = v
            }
            return .propertyChanged(handle: handle, iface: iface, props: props)
        case "ConfigChanged":
            return .configChanged(key: try requireText(m, "key"))
        case "OpProgress":
            let op = try requireUInt64(m, "op")
            // Enum-VALUE tolerance: an unrecognized phase is a FUTURE value,
            // not a malformed one — `OperationPhase(wireValue:)` never fails
            // (see the file doc comment).
            let phase = OperationPhase(wireValue: try requireWireEnumValue32(m, "phase"))
            let progress = try optionalDouble(m, "progress")
            let indeterminate = try optionalBool(m, "indeterminate")
            let watchdogSecs = try optionalUInt64(m, "watchdogSecs")
            return .opProgress(
                op: op, phase: phase, progress: progress, indeterminate: indeterminate, watchdogSecs: watchdogSecs)
        case "OpResultReady":
            let op = try requireUInt64(m, "op")
            guard let resultRaw = mapGet(m, "result") else { throw .missingField("result") }
            return .opResultReady(op: op, result: try parseOpResult(resultRaw))
        case "OpFinished":
            let op = try requireUInt64(m, "op")
            // Enum-VALUE tolerance: same as `phase` above, for both
            // `status` and `code`.
            let status = OperationStatus(wireValue: try requireWireEnumValue32(m, "status"))
            let code = ErrorCode(wireValue: try requireWireEnumValue32(m, "code"))
            let msgKey = try requireText(m, "msgKey")
            let msgFallback = try requireText(m, "msgFallback")
            return .opFinished(op: op, status: status, code: code, msgKey: msgKey, msgFallback: msgFallback)
        case "AgentQuiesced":
            // Enum-VALUE tolerance: same as `phase` above, but `reason` is
            // `uint8_t` on the wire (see the file doc comment), so this
            // bounds at `requireWireEnumValue8`, not `...32`.
            let reason = QuiesceReason(wireValue: try requireWireEnumValue8(m, "reason"))
            return .agentQuiesced(reason: reason)
        default:
            throw .unknownMessage
        }
    }
}

// MARK: - Shared parse helpers (sub-structures)

private func parseErrInfo(_ v: CBORValue) throws(MessageError) -> ErrInfo {
    let m = try requireMap(v, field: "err")
    let code: ErrInfo.Code
    if let codeRaw = mapGet(m, "code") {
        // Enum-VALUE tolerance: an unrecognized numeric code is a FUTURE
        // value, not a malformed one (see the file doc comment). Only a
        // non-numeric `code` or one too wide for `UInt32` is genuinely
        // malformed.
        guard let raw = numericUInt64(codeRaw) else { throw .wrongType("err.code") }
        guard raw <= UInt64(UInt32.max) else { throw .wrongType("err.code") }
        code = .code(ErrorCode(wireValue: UInt32(raw)))
    } else if let nameRaw = mapGet(m, "name") {
        guard case .text(let s) = nameRaw else { throw .wrongType("err.name") }
        // Enum-VALUE tolerance: `SyncError` is a TEXT-token enum, so an
        // unrecognized token DEGRADES AT DECODE to `.communicationError`
        // instead of failing this map (and the whole reply) closed — see
        // `SyncError`'s type doc comment.
        code = .name(SyncError(rawValue: s) ?? .communicationError)
    } else {
        throw .missingField("err.code|err.name")
    }
    let msgKey = try optionalText(m, "msgKey")
    let msgFallback = try optionalText(m, "msgFallback")
    return ErrInfo(code: code, msgKey: msgKey, msgFallback: msgFallback)
}

private func parseReaderState(_ v: CBORValue) throws(MessageError) -> ReaderState {
    let m = try requireMap(v, field: "reader")
    return ReaderState(
        handle: try requireText(m, "handle"),
        name: try requireText(m, "name"),
        hasCard: try requireBool(m, "hasCard"),
        card: try optionalText(m, "card"))
}

private func parseCardState(_ v: CBORValue) throws(MessageError) -> CardState {
    let m = try requireMap(v, field: "card")
    let capsRaw = try requireUInt64(m, "caps")
    // Enum-VALUE tolerance: an unrecognized preAuth value is a FUTURE
    // unlock method, not a malformed one (see the file doc comment); what
    // it MEANS is decided by `CardPresence.resolveCardState`, not here.
    // `preAuth` is `uint8_t` on the wire, so this bounds at
    // `requireWireEnumValue8`, not `...32`.
    let preAuth = PreReadAuth(wireValue: try requireWireEnumValue8(m, "preAuth"))
    return CardState(
        handle: try requireText(m, "handle"),
        reader: try requireText(m, "reader"),
        caps: Capabilities(rawValue: UInt32(truncatingIfNeeded: capsRaw)),
        preAuth: preAuth)
}

private func parseCertField(_ v: CBORValue) throws(MessageError) -> CertField {
    guard case .array(let a) = v, a.count == 3 else { throw .wrongType("cert-field") }
    guard case .text(let labelKey) = a[0], case .text(let labelFallback) = a[1], case .text(let value) = a[2] else {
        throw .wrongType("cert-field")
    }
    return CertField(labelKey: labelKey, labelFallback: labelFallback, value: value)
}

private func parseCertFieldGroups(_ v: CBORValue) throws(MessageError) -> [String: [String: CertField]] {
    let outer = try requireMap(v, field: "fields")
    var result: [String: [String: CertField]] = [:]
    for (groupKeyData, groupValue) in outer {
        let groupKey = String(decoding: groupKeyData, as: UTF8.self)
        let inner = try requireMap(groupValue, field: groupKey)
        var innerResult: [String: CertField] = [:]
        for (fieldKeyData, fieldValue) in inner {
            innerResult[String(decoding: fieldKeyData, as: UTF8.self)] = try parseCertField(fieldValue)
        }
        result[groupKey] = innerResult
    }
    return result
}

private func parseIdentityFieldCell(_ v: CBORValue) throws(MessageError) -> IdentityField {
    guard case .array(let a) = v, a.count == 4 else { throw .wrongType("id-field") }
    guard case .text(let labelKey) = a[0], case .text(let labelFallback) = a[1], case .text(let type) = a[2] else {
        throw .wrongType("id-field")
    }
    let value: IdentityFieldValue
    switch a[3] {
    case .text(let s):
        value = .text(s)
    case .bytes(let b):
        value = .binary(b)
    default:
        throw .wrongType("id-field.value")
    }
    return IdentityField(labelKey: labelKey, labelFallback: labelFallback, type: type, value: value)
}

private func parseIdentityFieldGroups(_ v: CBORValue) throws(MessageError) -> [String: [String: IdentityField]] {
    let outer = try requireMap(v, field: "fields")
    var result: [String: [String: IdentityField]] = [:]
    for (groupKeyData, groupValue) in outer {
        let groupKey = String(decoding: groupKeyData, as: UTF8.self)
        let inner = try requireMap(groupValue, field: groupKey)
        var innerResult: [String: IdentityField] = [:]
        for (fieldKeyData, fieldValue) in inner {
            innerResult[String(decoding: fieldKeyData, as: UTF8.self)] = try parseIdentityFieldCell(fieldValue)
        }
        result[groupKey] = innerResult
    }
    return result
}

private func parseCertInfo(_ v: CBORValue) throws(MessageError) -> CertificateInfo {
    let m = try requireMap(v, field: "cert-info")
    guard let fieldsRaw = mapGet(m, "fields") else { throw .missingField("fields") }
    let ekusArr = try requireArray(m, "ekus")
    var ekus: [String] = []
    for item in ekusArr {
        guard case .text(let s) = item else { throw .wrongType("ekus") }
        ekus.append(s)
    }
    let chainArr = try requireArray(m, "chainSubjectCns")
    var chainSubjectCns: [String] = []
    for item in chainArr {
        guard case .text(let s) = item else { throw .wrongType("chainSubjectCns") }
        chainSubjectCns.append(s)
    }
    return CertificateInfo(
        certId: try requireText(m, "certId"),
        signingCapable: try requireBool(m, "signingCapable"),
        fields: try parseCertFieldGroups(fieldsRaw),
        keyUsageBits: UInt32(truncatingIfNeeded: try requireUInt64(m, "keyUsageBits")),
        ekus: ekus,
        chainSubjectCns: chainSubjectCns,
        trustStatus: UInt32(truncatingIfNeeded: try requireUInt64(m, "trustStatus")))
}

private func parseSignMeta(_ v: CBORValue) throws(MessageError) -> SignMeta {
    let m = try requireMap(v, field: "meta")
    return SignMeta(
        format: try requireText(m, "format"),
        level: try requireText(m, "level"),
        tsaUsed: try requireBool(m, "tsaUsed"),
        chainComplete: try requireBool(m, "chainComplete"))
}

/// Parses a `sign-result` shape (`{kind:"Sign", artifact, meta}`) — used
/// both for the `SignRecovery` reply's `result` field (always this exact
/// shape) and for the `Sign` arm of a generic `op-result`.
private func parseSignResult(_ v: CBORValue) throws(MessageError) -> SignResult {
    let m = try requireMap(v, field: "result")
    let kind = try requireText(m, "kind")
    guard kind == "Sign" else { throw .wrongType("kind") }
    guard let metaRaw = mapGet(m, "meta") else { throw .missingField("meta") }
    return SignResult(artifact: try requireUInt64(m, "artifact"), meta: try parseSignMeta(metaRaw))
}

/// Parses a generic `op-result` (`OpResultReady.result`), dispatched on
/// `kind`. Known past decode bug (do not repeat): `Certificates` carries
/// its cert list nested under `result.certs`, not top-level.
private func parseOpResult(_ v: CBORValue) throws(MessageError) -> OpResult {
    let m = try requireMap(v, field: "result")
    let kind = try requireText(m, "kind")
    switch kind {
    case "Identity":
        guard let fieldsRaw = mapGet(m, "fields") else { throw .missingField("fields") }
        return .identity(IdentityResult(fields: try parseIdentityFieldGroups(fieldsRaw)))
    case "Photo":
        let photosArr = try requireArray(m, "photos")
        var photos: [PhotoItem] = []
        for item in photosArr {
            let pm = try requireMap(item, field: "photo")
            photos.append(PhotoItem(key: try requireText(pm, "key"), fd: try requireUInt64(pm, "fd")))
        }
        return .photo(PhotoResult(photos: photos))
    case "Certificates":
        let certsArr = try requireArray(m, "certs")
        var certs: [CertificateInfo] = []
        for item in certsArr {
            certs.append(try parseCertInfo(item))
        }
        return .certificates(certs)
    case "Sign":
        return .sign(try parseSignResult(v))
    case "Credentials":
        guard let credResultRaw = mapGet(m, "result") else { throw .missingField("result") }
        let recordsArr = try requireArray(m, "records")
        var records: [CredentialRecord] = []
        for item in recordsArr {
            records.append(try parseCredRecord(item))
        }
        return .credentials(CredentialsPayload(result: try parseCredResult(credResultRaw), records: records))
    default:
        throw .wrongType("kind")
    }
}

/// Parses a `cred-result` shape. `outcome` DEGRADES AT DECODE to
/// `.unspecified` for an unrecognized token (`CredentialOutcome`'s type
/// doc comment — the `SyncError` precedent); the optional keys are
/// omitted-when-absent on the wire.
private func parseCredResult(_ v: CBORValue) throws(MessageError) -> CredentialResult {
    let m = try requireMap(v, field: "result")
    let token = try requireText(m, "outcome")
    let outcome = CredentialOutcome(rawValue: token) ?? .unspecified
    return CredentialResult(
        outcome: outcome,
        retriesLeft: try optionalUInt32(m, "retriesLeft"),
        blocked: try requireBool(m, "blocked"),
        pinActivated: try optionalBool(m, "pinActivated"),
        keyActivated: try optionalBool(m, "keyActivated"))
}

/// Parses one `cred-record` (23 wire keys). The four token-valued enum
/// fields decode via `init(token:)` — unrecognized tokens degrade to
/// `.unknown` (see `CredentialKind`), the same decode-time-degrade shape
/// `outcome` above uses (to `.unspecified` instead, since `.unknown` is
/// not part of `cred-outcome`'s wire vocabulary).
private func parseCredRecord(_ v: CBORValue) throws(MessageError) -> CredentialRecord {
    let m = try requireMap(v, field: "cred-record")
    return CredentialRecord(
        id: try requireText(m, "id"),
        label: try requireText(m, "label"),
        kind: CredentialKind(token: try requireText(m, "kind")),
        state: CredentialState(token: try requireText(m, "state")),
        retriesLeft: try optionalUInt32(m, "retriesLeft"),
        retriesMax: try optionalUInt32(m, "retriesMax"),
        usesLeft: try optionalUInt32(m, "usesLeft"),
        usesMax: try optionalUInt32(m, "usesMax"),
        unblocksLeft: try optionalUInt32(m, "unblocksLeft"),
        minLength: try optionalUInt32(m, "minLength"),
        maxLength: try optionalUInt32(m, "maxLength"),
        canChange: try requireBool(m, "canChange"),
        unblockable: try requireBool(m, "unblockable"),
        unblockStyle: CredentialUnblockStyle(token: try requireText(m, "unblockStyle")),
        activatable: try requireBool(m, "activatable"),
        keyActivationPending: try requireBool(m, "keyActivationPending"),
        keyActivatable: try requireBool(m, "keyActivatable"),
        recovery: CredentialRecovery(token: try requireText(m, "recovery")),
        probeSafe: try requireBool(m, "probeSafe"),
        blockedGuidanceKey: try optionalText(m, "blockedGuidanceKey"),
        blockedGuidanceFallback: try optionalText(m, "blockedGuidanceFallback"),
        keyActivationGuidanceKey: try optionalText(m, "keyActivationGuidanceKey"),
        keyActivationGuidanceFallback: try optionalText(m, "keyActivationGuidanceFallback"))
}

// MARK: - CBORValue accessor primitives

private func decodeCanonical(_ body: Data) throws(MessageError) -> CBORValue {
    do {
        return try CBORValue.decode(body)
    } catch {
        throw .notCanonicalCBOR(error)
    }
}

private func requireTopLevelMap(_ v: CBORValue) throws(MessageError) -> [(Data, CBORValue)] {
    guard case .map(let m) = v else { throw .notAMap }
    return m
}

private func requireMap(_ v: CBORValue, field: String) throws(MessageError) -> [(Data, CBORValue)] {
    guard case .map(let m) = v else { throw .wrongType(field) }
    return m
}

private func mapGet(_ m: [(Data, CBORValue)], _ key: String) -> CBORValue? {
    let keyData = Data(key.utf8)
    for (k, v) in m where k == keyData {
        return v
    }
    return nil
}

private func numericUInt64(_ v: CBORValue) -> UInt64? {
    switch v {
    case .int(let i) where i >= 0:
        return UInt64(i)
    case .uint(let u):
        return u
    default:
        return nil
    }
}

private func requireText(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> String {
    guard let raw = mapGet(m, key) else { throw .missingField(key) }
    guard case .text(let s) = raw else { throw .wrongType(key) }
    return s
}

private func requireTextArray(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> [String] {
    let arr = try requireArray(m, key)
    var result: [String] = []
    for item in arr {
        guard case .text(let s) = item else { throw .wrongType(key) }
        result.append(s)
    }
    return result
}

private func requireUInt64(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> UInt64 {
    guard let raw = mapGet(m, key) else { throw .missingField(key) }
    guard let u = numericUInt64(raw) else { throw .wrongType(key) }
    return u
}

/// Width-bounded `UInt64` -> `UInt32` conversion for the three numeric wire
/// enum fields whose C++ storage is `uint32_t` (`phase`, `status`, `code`):
/// rejects ONLY a value too wide for `UInt32` to represent losslessly — a
/// genuinely malformed frame (two distinct future values silently aliasing
/// onto one stored value) — mirroring the C++ codec's `static_cast` width
/// guard (`ClientCodec.cpp`'s `decodeOperationPhase` / `decodeOperationStatus`
/// / the `ErrorCode` decoder). Never rejects merely because the value has
/// no case name yet — that tolerance lives in each enum's
/// `init(wireValue:)`, called by every caller of this helper (see the file
/// doc comment). For the two `uint8_t`-storage enums (`preAuth`, `reason`),
/// see `requireWireEnumValue8` below instead.
private func requireWireEnumValue32(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> UInt32 {
    let raw = try requireUInt64(m, key)
    guard raw <= UInt64(UInt32.max) else { throw .wrongType(key) }
    return UInt32(raw)
}

/// Width-bounded `UInt64` -> `UInt32` conversion for the two numeric wire
/// enum fields whose C++ storage is `uint8_t` (`preAuth`, `reason`): rejects
/// a value too wide for `UInt8` to represent losslessly, mirroring the
/// C++ codec's `static_cast` width guard (`ClientCodec.cpp`'s
/// `decodePreReadAuth` / `decodeQuiesceReason`). The return type is still
/// `UInt32` (not `UInt8`) purely so the bounded value plugs straight into
/// `PreReadAuth.init(wireValue:)` / `QuiesceReason.init(wireValue:)`, whose
/// `.unknown` case carries a `UInt32` for shape-uniformity with the other
/// three enums — only the ACCEPTED range differs here, not the Swift-side
/// storage type. Never rejects merely because the value has no case name
/// yet — that tolerance lives in each enum's `init(wireValue:)`, called by
/// every caller of this helper (see the file doc comment).
private func requireWireEnumValue8(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> UInt32 {
    let raw = try requireUInt64(m, key)
    guard raw <= UInt64(UInt8.max) else { throw .wrongType(key) }
    return UInt32(raw)
}

private func requireBool(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> Bool {
    guard let raw = mapGet(m, key) else { throw .missingField(key) }
    guard case .bool(let b) = raw else { throw .wrongType(key) }
    return b
}

private func requireArray(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> [CBORValue] {
    guard let raw = mapGet(m, key) else { throw .missingField(key) }
    guard case .array(let a) = raw else { throw .wrongType(key) }
    return a
}

private func optionalText(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> String? {
    guard let raw = mapGet(m, key) else { return nil }
    guard case .text(let s) = raw else { throw .wrongType(key) }
    return s
}

private func optionalBool(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> Bool? {
    guard let raw = mapGet(m, key) else { return nil }
    guard case .bool(let b) = raw else { throw .wrongType(key) }
    return b
}

private func optionalDouble(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> Double? {
    guard let raw = mapGet(m, key) else { return nil }
    guard case .double(let d) = raw else { throw .wrongType(key) }
    return d
}

private func optionalUInt64(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> UInt64? {
    guard let raw = mapGet(m, key) else { return nil }
    guard let u = numericUInt64(raw) else { throw .wrongType(key) }
    return u
}

private func optionalUInt32(_ m: [(Data, CBORValue)], _ key: String) throws(MessageError) -> UInt32? {
    guard let u = try optionalUInt64(m, key) else { return nil }
    return UInt32(truncatingIfNeeded: u)
}

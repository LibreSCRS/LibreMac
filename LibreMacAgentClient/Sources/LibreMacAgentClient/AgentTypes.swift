// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

// Value types for the LibreMac agent wire protocol. These mirror the
// LibreDarwin agent's `LibreSCRS::Darwin::wire` C++ types (`Messages.h`) and
// the reconciled CDDL contract (`wire/librescrs-agent.cddl`, LibreAgent
// repo) that both implementations round-trip against. Enum raw values are
// wire-significant and locked to the upstream numbering; never renumber
// existing cases.

// MARK: - Wire-mirrored enums

/// Stable agent-side error taxonomy, carried as the numeric `code` arm of a
/// reply's `err` field and as `OpFinished.code`. Mirrors
/// `LibreSCRS::Agent::ErrorCode` (LibreAgent) and the CDDL `error-code`
/// group. 21 values, append-only — never renumber.
///
/// Wire tolerance: `error-code` is wire-frozen append-only, so a newer agent
/// may send a code past `entryExpired` — this build simply does not have
/// a name for it yet, which is a FUTURE value, not a malformed one. Decode
/// never fails the frame over it (`ClientCodec.h`'s tolerance table — this
/// was the ORIGINAL tolerance this wire shipped with). Unlike the
/// synthesized-`RawRepresentable` enum this used to be — whose
/// `init?(rawValue:)` returns `nil` for a value with no case, exactly the
/// fail-closed behavior this type must NOT have — `ErrorCode` carries an
/// `.unknown(UInt32)` case instead and hand-rolls `init(wireValue:)` /
/// `wireValue` rather than `RawRepresentable`. `OperationPhase` /
/// `OperationStatus` / `PreReadAuth` / `QuiesceReason` below follow the
/// identical shape for the identical reason. The client treats the value as
/// opaque display/log data and never branches on it — true before this
/// policy existed and true for `.unknown` codes now.
public enum ErrorCode: Sendable, Equatable {
    case none
    case cardRemoved
    case credentialWrong
    case credentialBlocked
    case communicationError
    case parseError
    case unsupportedCard
    case authFailed
    case prompterError
    case capabilityMissing
    case watchdogTimeout
    case keyNotFound
    case keyAmbiguous
    case certExpiredBlocked
    case chainIncomplete
    case tsaUnreachable
    case signingEngineError
    case rateLimited
    case engineUnavailable
    case invalidDocument
    case entryExpired
    /// A code this build does not have a name for yet — carries the raw
    /// wire value verbatim (see the type doc comment).
    case unknown(UInt32)
}

extension ErrorCode {
    /// Decodes a width-bounded wire value (the bounds check itself lives in
    /// `Messages.swift`'s `requireWireEnumValue32`, shared with
    /// `OperationPhase`/`OperationStatus` — the three numeric enums whose
    /// wire storage is `uint32_t`; `PreReadAuth`/`QuiesceReason` are
    /// `uint8_t`-bounded instead, via `requireWireEnumValue8`) into a
    /// `ErrorCode`. Never fails: an unrecognized value becomes
    /// `.unknown(wireValue)`.
    public init(wireValue: UInt32) {
        switch wireValue {
        case 0: self = .none
        case 1: self = .cardRemoved
        case 2: self = .credentialWrong
        case 3: self = .credentialBlocked
        case 4: self = .communicationError
        case 5: self = .parseError
        case 6: self = .unsupportedCard
        case 7: self = .authFailed
        case 8: self = .prompterError
        case 9: self = .capabilityMissing
        case 10: self = .watchdogTimeout
        case 11: self = .keyNotFound
        case 12: self = .keyAmbiguous
        case 13: self = .certExpiredBlocked
        case 14: self = .chainIncomplete
        case 15: self = .tsaUnreachable
        case 16: self = .signingEngineError
        case 17: self = .rateLimited
        case 18: self = .engineUnavailable
        case 19: self = .invalidDocument
        case 20: self = .entryExpired
        default: self = .unknown(wireValue)
        }
    }

    /// Inverse of `init(wireValue:)` — the encode direction, used by test
    /// fixture construction (the client itself only ever decodes an
    /// `ErrorCode`, never encodes one onto the wire).
    public var wireValue: UInt32 {
        switch self {
        case .none: return 0
        case .cardRemoved: return 1
        case .credentialWrong: return 2
        case .credentialBlocked: return 3
        case .communicationError: return 4
        case .parseError: return 5
        case .unsupportedCard: return 6
        case .authFailed: return 7
        case .prompterError: return 8
        case .capabilityMissing: return 9
        case .watchdogTimeout: return 10
        case .keyNotFound: return 11
        case .keyAmbiguous: return 12
        case .certExpiredBlocked: return 13
        case .chainIncomplete: return 14
        case .tsaUnreachable: return 15
        case .signingEngineError: return 16
        case .rateLimited: return 17
        case .engineUnavailable: return 18
        case .invalidDocument: return 19
        case .entryExpired: return 20
        case .unknown(let v): return v
        }
    }

    /// `true` for every case except `.unknown` — a future value this build
    /// does not have a name for yet. See the type doc comment.
    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    /// The name this code carries in the wire contract. The numeric enums
    /// send only a value, so a name mismatch cannot corrupt a frame — it
    /// silently attaches the wrong copy to the right number, which is worse
    /// to debug. Exhaustive on purpose: an added case must name itself here.
    public var wireName: String {
        switch self {
        case .none: return "None"
        case .cardRemoved: return "CardRemoved"
        case .credentialWrong: return "CredentialWrong"
        case .credentialBlocked: return "CredentialBlocked"
        case .communicationError: return "CommunicationError"
        case .parseError: return "ParseError"
        case .unsupportedCard: return "UnsupportedCard"
        case .authFailed: return "AuthFailed"
        case .prompterError: return "PrompterError"
        case .capabilityMissing: return "CapabilityMissing"
        case .watchdogTimeout: return "WatchdogTimeout"
        case .keyNotFound: return "KeyNotFound"
        case .keyAmbiguous: return "KeyAmbiguous"
        case .certExpiredBlocked: return "CertExpiredBlocked"
        case .chainIncomplete: return "ChainIncomplete"
        case .tsaUnreachable: return "TsaUnreachable"
        case .signingEngineError: return "SigningEngineError"
        case .rateLimited: return "RateLimited"
        case .engineUnavailable: return "EngineUnavailable"
        case .invalidDocument: return "InvalidDocument"
        case .entryExpired: return "EntryExpired"
        case .unknown(let raw): return "unknown(\(raw))"
        }
    }
}

extension ErrorCode: CaseIterable {
    /// Hand-rolled (associated-value cases forbid synthesis): the 21 NAMED
    /// cases only. `.unknown` is not a discrete case to enumerate — it is
    /// an open-ended family of raw values — so it is deliberately excluded;
    /// `ErrorCopyTests.taxonomyHasTwentyOneValues` gates this count.
    public static var allCases: [ErrorCode] {
        [
            .none, .cardRemoved, .credentialWrong, .credentialBlocked, .communicationError,
            .parseError, .unsupportedCard, .authFailed, .prompterError, .capabilityMissing,
            .watchdogTimeout, .keyNotFound, .keyAmbiguous, .certExpiredBlocked, .chainIncomplete,
            .tsaUnreachable, .signingEngineError, .rateLimited, .engineUnavailable, .invalidDocument,
            .entryExpired,
        ]
    }
}

/// Named synchronous-method errors (D-Bus `Error.*` names), carried as the
/// string `name` arm of a reply's `err` field. Distinct from the numeric
/// `ErrorCode` — one or the other, never both (`err-info`,
/// `librescrs-agent.cddl`). The raw value IS the wire string,
/// mirroring the agent's sync-error names. 20 values.
///
/// Wire tolerance: `sync-error` is a TEXT-token closed enum, unlike the
/// numeric enums above/below — there is no width to bound an unrecognized
/// token against, so it DEGRADES AT DECODE (`parseErrInfo` in
/// `Messages.swift`) to `.communicationError` instead of failing the
/// `err-info` map (and the whole reply frame) closed. This is the exact
/// classification an unrecognized D-Bus error name already falls back to
/// on the other transport, so both transports converge on the same
/// generic-protocol-error outcome (`ClientCodec.h`'s tolerance table). The
/// original wire token is not retained on the degrade path — no case here
/// is a good typed home for arbitrary raw text.
public enum SyncError: String, Sendable, Equatable, CaseIterable {
    case unknownCard = "UnknownCard"
    case keyNotFound = "KeyNotFound"
    case notAuthorized = "NotAuthorized"
    case userNotLoggedIn = "UserNotLoggedIn"
    case unknownConfigKey = "UnknownConfigKey"
    case readOnlyConfig = "ReadOnlyConfig"
    case invalidConfigValue = "InvalidConfigValue"
    case unsupportedProtocol = "UnsupportedProtocol"
    case authFailed = "AuthFailed"
    case communicationError = "CommunicationError"
    case notSupported = "NotSupported"
    case unsupportedOnThisCard = "UnsupportedOnThisCard"
    case unsupportedSignatureParameter = "UnsupportedSignatureParameter"
    case inputTooLarge = "InputTooLarge"
    case rateLimited = "RateLimited"
    case unknownCredential = "UnknownCredential"
    case invalidRequest = "InvalidRequest"
    /// `getSignResult` has nothing to serve for the requested op: it never
    /// reached a retained Sign result (wrong kind, never completed, or the
    /// recovery grace window elapsed), or the caller does not own it — the
    /// two are deliberately indistinguishable on the wire (an IDOR-safe agent
    /// answers a not-mine op exactly like an absent one). Previously served
    /// ad hoc (a borrowed name); this is the dedicated one.
    case noResult = "NoResult"
    case masterListReplayed = "MasterListReplayed"
    /// The person dismissed the prompt the request raised. Not a failure: the
    /// card is fine and nothing was refused, so a caller that shows this as a
    /// device error takes the token away from someone who only wanted to
    /// answer the prompt on the second try. The bus transport has carried this
    /// name from the start; the socket wire gained it so both can be held to
    /// one answer.
    case cancelled = "Cancelled"
}

/// `Operation1` progress phase. Mirrors
/// `LibreSCRS::Agent::Operations::OperationPhase` (LibreAgent) and CDDL
/// `op-phase` (`librescrs-agent.cddl`). Append-only.
///
/// Wire tolerance: like `ErrorCode` above, a value past `done` is a FUTURE
/// phase, not a malformed one — carried through as `.unknown(UInt32)`
/// rather than failing decode. Degradation is a STATEFUL-layer concern,
/// never this type's or the codec's: `OperationDriver`'s `StallWatch` holds
/// the last known-good phase for its watchdog-exemption check (never
/// regressing to an unrecognized value), and `SigningCoordinator.applyPhase`
/// leaves its rendered stage unchanged on `.unknown` for the identical
/// reason (`ClientCodec.h`'s tolerance table names `AgentOperation` as the
/// C++ analog; the CDDL `op-phase` comment names the Swift mirror's
/// `OperationDriver`).
public enum OperationPhase: Sendable, Equatable {
    case created
    case connecting
    case awaitingConsent
    case authenticating
    case reading
    case signing
    case timestamping
    case done
    /// A phase this build does not have a name for yet — carries the raw
    /// wire value verbatim (see the type doc comment).
    case unknown(UInt32)
}

extension OperationPhase {
    /// See `ErrorCode.init(wireValue:)` — identical shape, never fails.
    public init(wireValue: UInt32) {
        switch wireValue {
        case 0: self = .created
        case 1: self = .connecting
        case 2: self = .awaitingConsent
        case 3: self = .authenticating
        case 4: self = .reading
        case 5: self = .signing
        case 6: self = .timestamping
        case 7: self = .done
        default: self = .unknown(wireValue)
        }
    }

    /// Inverse of `init(wireValue:)` — the encode direction (test fixture
    /// construction).
    public var wireValue: UInt32 {
        switch self {
        case .created: return 0
        case .connecting: return 1
        case .awaitingConsent: return 2
        case .authenticating: return 3
        case .reading: return 4
        case .signing: return 5
        case .timestamping: return 6
        case .done: return 7
        case .unknown(let v): return v
        }
    }

    /// `true` for every case except `.unknown`. See `ErrorCode.isKnown`.
    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    /// The name this phase carries in the wire contract. See
    /// `ErrorCode.wireName` for why numeric enums name themselves.
    public var wireName: String {
        switch self {
        case .created: return "Created"
        case .connecting: return "Connecting"
        case .awaitingConsent: return "AwaitingConsent"
        case .authenticating: return "Authenticating"
        case .reading: return "Reading"
        case .signing: return "Signing"
        case .timestamping: return "Timestamping"
        case .done: return "Done"
        case .unknown(let raw): return "unknown(\(raw))"
        }
    }
}

/// Terminal `Operation1.Finished` status. Mirrors
/// `LibreSCRS::Agent::Operations::OperationStatus` (LibreAgent) and CDDL
/// `op-status` (`librescrs-agent.cddl`).
///
/// Wire tolerance: like `OperationPhase` above, a value past `error` is a
/// FUTURE status carried through as `.unknown(UInt32)`. The stateful layer
/// that treats an unrecognized terminal status as `Error` is
/// `OperationDriver.driveToFinished` (`ClientCodec.h`'s tolerance table).
public enum OperationStatus: Sendable, Equatable {
    case ok
    case cancelled
    case error
    /// A status this build does not have a name for yet — carries the raw
    /// wire value verbatim (see the type doc comment).
    case unknown(UInt32)
}

extension OperationStatus {
    /// See `ErrorCode.init(wireValue:)` — identical shape, never fails.
    public init(wireValue: UInt32) {
        switch wireValue {
        case 0: self = .ok
        case 1: self = .cancelled
        case 2: self = .error
        default: self = .unknown(wireValue)
        }
    }

    /// Inverse of `init(wireValue:)` — the encode direction (test fixture
    /// construction).
    public var wireValue: UInt32 {
        switch self {
        case .ok: return 0
        case .cancelled: return 1
        case .error: return 2
        case .unknown(let v): return v
        }
    }

    /// `true` for every case except `.unknown`. See `ErrorCode.isKnown`.
    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    /// The name this status carries in the wire contract. See
    /// `ErrorCode.wireName` for why numeric enums name themselves.
    public var wireName: String {
        switch self {
        case .ok: return "Ok"
        case .cancelled: return "Cancelled"
        case .error: return "Error"
        case .unknown(let raw): return "unknown(\(raw))"
        }
    }
}

/// Socket-only lifecycle vocabulary — no upstream core enum, macOS-specific
/// (system sleep / screen lock / session switch / shutdown quiesce). Mirrors
/// `LibreSCRS::Darwin::wire::QuiesceReason` (LibreDarwin) and CDDL
/// `quiesce-reason` (`librescrs-agent.cddl`).
///
/// Wire tolerance: append-only, like `PreReadAuth` below; a value past
/// `shutdown` is a FUTURE reason carried through as `.unknown(UInt32)`.
/// Nothing branches on this value today, so an unrecognized reason is
/// inertly a "generic quiesce" wherever it is rendered (`ClientCodec.h`'s
/// tolerance table) — no separate mapping layer is needed.
public enum QuiesceReason: Sendable, Equatable {
    case systemSleep
    case screenLocked
    case sessionInactive
    case shutdown
    /// A reason this build does not have a name for yet — carries the raw
    /// wire value verbatim (see the type doc comment).
    case unknown(UInt32)
}

extension QuiesceReason {
    /// See `ErrorCode.init(wireValue:)` — identical shape, never fails.
    public init(wireValue: UInt32) {
        switch wireValue {
        case 0: self = .systemSleep
        case 1: self = .screenLocked
        case 2: self = .sessionInactive
        case 3: self = .shutdown
        default: self = .unknown(wireValue)
        }
    }

    /// Inverse of `init(wireValue:)` — the encode direction (test fixture
    /// construction).
    public var wireValue: UInt32 {
        switch self {
        case .systemSleep: return 0
        case .screenLocked: return 1
        case .sessionInactive: return 2
        case .shutdown: return 3
        case .unknown(let v): return v
        }
    }

    /// `true` for every case except `.unknown`. See `ErrorCode.isKnown`.
    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    /// The name this reason carries in the wire contract. See
    /// `ErrorCode.wireName` for why numeric enums name themselves.
    public var wireName: String {
        switch self {
        case .systemSleep: return "SystemSleep"
        case .screenLocked: return "ScreenLocked"
        case .sessionInactive: return "SessionInactive"
        case .shutdown: return "Shutdown"
        case .unknown(let raw): return "unknown(\(raw))"
        }
    }
}

/// Pre-read unlock mechanism for travel-document-style cards. Mirrors
/// `LibreSCRS::Auth::PreReadAuthMethod` (LibreMiddleware
/// `include/LibreSCRS/Auth/AuthRequirement.h` — `None`/`Mrz`/`Can`)
/// and CDDL `pre-read-auth` (`librescrs-agent.cddl`).
///
/// Wire tolerance: append-only; a value past `can` is a FUTURE unlock
/// method this build does not name yet, carried through as
/// `.unknown(UInt32)`. The card-property mapping layer
/// (`CardPresence.resolveCardState` in the LibreMac app target) latches on an
/// unrecognized value as it would on any unlock method — deciding what an
/// unrecognized value MEANS is that layer's job, never this type's or the
/// codec's (`ClientCodec.h`'s tolerance table).
public enum PreReadAuth: Sendable, Equatable {
    case none
    case mrz
    case can
    /// A method this build does not have a name for yet — carries the raw
    /// wire value verbatim (see the type doc comment).
    case unknown(UInt32)
}

extension PreReadAuth {
    /// See `ErrorCode.init(wireValue:)` — identical shape, never fails.
    public init(wireValue: UInt32) {
        switch wireValue {
        case 0: self = .none
        case 1: self = .mrz
        case 2: self = .can
        default: self = .unknown(wireValue)
        }
    }

    /// Inverse of `init(wireValue:)` — the encode direction (test fixture
    /// construction).
    public var wireValue: UInt32 {
        switch self {
        case .none: return 0
        case .mrz: return 1
        case .can: return 2
        case .unknown(let v): return v
        }
    }

    /// `true` for every case except `.unknown`. See `ErrorCode.isKnown`.
    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    /// The name this method carries in the wire contract. See
    /// `ErrorCode.wireName` for why numeric enums name themselves.
    public var wireName: String {
        switch self {
        case .none: return "None"
        case .mrz: return "Mrz"
        case .can: return "Can"
        case .unknown(let raw): return "unknown(\(raw))"
        }
    }
}

/// Card capability bitmask carried as `CardState.caps` (a raw `uint32` on
/// the wire — see the C++ `CardState::caps` comment in the LibreDarwin
/// agent's wire types). Bit positions mirror the CDDL `capability-bit`
/// group (`librescrs-agent.cddl`); there is no dedicated upstream C++
/// enum for this bitmask today.
public struct Capabilities: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// One case per capability bit. `OptionSet` carries no enumeration of its
    /// own and Swift reflection does not see static properties, so without
    /// this a test could only check the bits it was separately told about —
    /// another hand-kept copy of the very thing it is meant to be verifying.
    public enum Bit: UInt32, CaseIterable, Sendable {
        case pki = 0
        case identityData = 1
        case emrtdCrypto = 2
        case pinManagement = 3

        public var wireName: String {
            switch self {
            case .pki: return "Pki"
            case .identityData: return "IdentityData"
            case .emrtdCrypto: return "EmrtdCrypto"
            case .pinManagement: return "PinManagement"
            }
        }
    }

    public init(bit: Bit) {
        self.init(rawValue: 1 << bit.rawValue)
    }

    public static let pki = Capabilities(bit: .pki)
    public static let identityData = Capabilities(bit: .identityData)
    public static let emrtdCrypto = Capabilities(bit: .emrtdCrypto)
    public static let pinManagement = Capabilities(bit: .pinManagement)
}

// MARK: - Config wire enum (Config1 seam)

/// The closed set of `Config1` keys a client may WRITE — CDDL
/// `settable-config-key`. The raw value IS the wire token. Deliberately
/// narrower than every other config key on the wire: `TslCacheDir` /
/// `AiaCacheDir` / `PluginDir` are file-only (a wire-settable `PluginDir`
/// is a `dlopen` code-exec vector) and `LastTsaUrl` / `CscaAnchorState` are
/// read-only agent state, so none of the five are constructible here — see
/// `AgentRequest.resetConfig`'s own doc comment for the wider rule those
/// five belong to.
public enum SettableConfigKey: String, Sendable, Equatable, CaseIterable {
    case defaultLevel = "DefaultLevel"
    case defaultReason = "DefaultReason"
    case defaultLocation = "DefaultLocation"
    case tsaUrls = "TsaUrls"
    case tslSources = "TslSources"
    case cscaSources = "CscaSources"
}

/// One configured country-signing source, the element type of the `CscaSources`
/// config value. Mirrors `LibreSCRS::Agent::Config::CscaSource`, which the
/// agent builds from exactly these TWO map keys.
///
/// Two members, not three. `TslSource` below carries an `isLotl` flag because a
/// trusted list can be a list OF lists; country-signing anchors have no such
/// pivot, so a third field added here for symmetry would be a value with
/// nothing to put in it and a wire key the agent never reads. The asymmetry is
/// the decision, not an omission.
public struct CscaSource: Sendable, Equatable {
    public var uri: String
    public var eager: Bool

    public init(uri: String, eager: Bool = false) {
        self.uri = uri
        self.eager = eager
    }

    /// Decodes one wire map. A source without a `uri` is not a source, so it
    /// yields nil rather than an entry the user cannot act on; `eager` defaults
    /// to false exactly as the agent's own decode does.
    public init?(cbor: CBORValue) {
        guard case .map(let pairs) = cbor else { return nil }
        func value(_ key: String) -> CBORValue? {
            let wanted = Data(key.utf8)
            for (k, v) in pairs where k == wanted { return v }
            return nil
        }
        guard case .text(let uri)? = value("uri"), !uri.isEmpty else { return nil }
        self.uri = uri
        if case .bool(let b)? = value("eager") { self.eager = b } else { self.eager = false }
    }

    /// The wire map. `eager` is always written: absence is not distinguishable
    /// from false by a reader, and a round-trip that silently dropped a set
    /// flag would change when the agent reaches the network.
    public var cbor: CBORValue {
        .map([
            (Data("uri".utf8), .text(uri)),
            (Data("eager".utf8), .bool(eager)),
        ])
    }
}

/// One configured trusted-list source, the element type of the `TslSources`
/// config value. Mirrors `LibreSCRS::Agent::Config::TslSource`, which the
/// agent builds from exactly these three map keys.
///
/// `isLotl` marks a list-of-trusted-lists (a list whose entries are
/// themselves lists); `eager` asks the agent to fetch it up front rather
/// than on first need.
public struct TslSource: Sendable, Equatable {
    public var url: String
    public var isLotl: Bool
    public var eager: Bool

    public init(url: String, isLotl: Bool = false, eager: Bool = false) {
        self.url = url
        self.isLotl = isLotl
        self.eager = eager
    }

    /// Decodes one wire map. A source without a `url` is not a source, so it
    /// yields nil rather than an entry the user cannot act on; the two flags
    /// default to false exactly as the agent's own decode does, so a map
    /// written by an older agent still reads.
    public init?(cbor: CBORValue) {
        guard case .map(let pairs) = cbor else { return nil }
        func value(_ key: String) -> CBORValue? {
            let wanted = Data(key.utf8)
            for (k, v) in pairs where k == wanted { return v }
            return nil
        }
        func flag(_ key: String) -> Bool {
            if case .bool(let b)? = value(key) { return b }
            return false
        }
        guard case .text(let url)? = value("url"), !url.isEmpty else { return nil }
        self.url = url
        self.isLotl = flag("isLotl")
        self.eager = flag("eager")
    }

    /// The wire map. Both flags are always written: unlike the display fields
    /// on the prompter wire, absence here is not distinguishable from false
    /// by a reader, and a round-trip that silently drops a set flag would
    /// change what the agent trusts.
    public var cbor: CBORValue {
        // Order is irrelevant here: the encoder sorts map keys canonically on
        // the way out, which is what the agent requires.
        .map([
            (Data("url".utf8), .text(url)),
            (Data("isLotl".utf8), .bool(isLotl)),
            (Data("eager".utf8), .bool(eager)),
        ])
    }
}

/// What the agent believes about its country-signing anchors — the value of
/// the read-only `CscaAnchorState` config key, and the same dict
/// `ImportCscaMasterList` replies with (minus the `kind` discriminator only a
/// reply arm needs). Mirrors the CDDL `csca-anchor-state` group field-for-field.
///
/// A client that has just started has no import reply to read, which is the
/// whole reason the config key exists: without it a freshly launched host
/// could only say that what passports are checked against cannot be known.
///
/// `anchors` counts anchors INCLUDING CSCA link certificates — link
/// certificates are anchors like any other — so it is not a count of
/// self-signed roots. `issuers` is the distinct issuing countries among them.
public struct CscaAnchorState: Sendable, Equatable {
    /// Anchors held, INCLUDING link certificates.
    public var anchors: UInt64
    /// Distinct issuing countries among those anchors.
    public var issuers: UInt64
    /// Whether a later import can be refused for rolling the anchors back.
    /// Its FALSE is the value worth showing: it means at least one accepted
    /// list carried no signing time, so "is this older than what I hold"
    /// cannot be answered at all, and a surface that stays silent leaves a
    /// person unable to tell "this is safe" from "this cannot be checked".
    /// The agent computes it across EVERY accepted publisher and reports
    /// false if ANY of them was undated, so it is not a fact about one list.
    ///
    /// Optional although the schema requires it, and the nil is load-bearing:
    /// a field that did not arrive must not be rendered as the false that
    /// warns, because that would turn a gap in the frame into a claim about
    /// what this computer can check.
    public var replayRefusalActive: Bool?
    /// Lowercase hex SHA-256 over the publisher's SubjectPublicKeyInfo.
    /// Absent when the import took in several publishers — there is then no
    /// single publisher to name.
    public var signer: String?
    /// Whether the import ESTABLISHED the publisher's identity rather than
    /// merely observing it. False after a trust-on-first-import.
    public var signerPinned: Bool?
    /// Seconds since the epoch when the AGENT accepted the list.
    public var acceptedAt: Int64?
    /// Seconds since the epoch the list says it was SIGNED. Absent when the
    /// list carried no signing time, which CMS permits; there is no zero
    /// sentinel, because a list signed at the epoch and a list with no date
    /// must not read alike.
    public var signedAt: Int64?
    /// Where the anchors came from. Carried so this type mirrors the contract
    /// group in full, but not rendered: "import" is the only value the agent
    /// sends, so a row for it would tell a person nothing they could act on.
    public var origin: String?

    public init(
        anchors: UInt64, issuers: UInt64, replayRefusalActive: Bool?,
        signer: String? = nil, signerPinned: Bool? = nil,
        acceptedAt: Int64? = nil, signedAt: Int64? = nil, origin: String? = nil
    ) {
        self.anchors = anchors
        self.issuers = issuers
        self.replayRefusalActive = replayRefusalActive
        self.signer = signer
        self.signerPinned = signerPinned
        self.acceptedAt = acceptedAt
        self.signedAt = signedAt
        self.origin = origin
    }

    /// Decodes the wire map. An EMPTY map is this wire's "nothing has been
    /// imported" and yields nil — absent is not a zeroed report, because a
    /// zeroed report would claim a list was accepted and vouched for nobody,
    /// which is a different thing and a false one.
    ///
    /// `replayRefusalActive` is required by the schema, but a map missing it
    /// decodes to nil rather than to false and rather than failing the value
    /// closed: the counts still stand, and a caller is left unable to make the
    /// affirmative "this cannot be checked" claim out of a field that never
    /// arrived.
    public init?(cbor: CBORValue) {
        guard case .map(let pairs) = cbor, !pairs.isEmpty else { return nil }
        func value(_ key: String) -> CBORValue? {
            let wanted = Data(key.utf8)
            for (k, v) in pairs where k == wanted { return v }
            return nil
        }
        func count(_ key: String) -> UInt64? {
            switch value(key) {
            case .uint(let u): return u
            case .int(let i): return i >= 0 ? UInt64(i) : nil
            default: return nil
            }
        }
        func stamp(_ key: String) -> Int64? {
            switch value(key) {
            case .int(let i): return i
            case .uint(let u): return u <= UInt64(Int64.max) ? Int64(u) : nil
            default: return nil
            }
        }
        // A report without its counts is not a report.
        guard let anchors = count("anchors"), let issuers = count("issuers") else { return nil }
        self.anchors = anchors
        self.issuers = issuers
        if case .bool(let active)? = value("replayRefusalActive") {
            self.replayRefusalActive = active
        } else {
            self.replayRefusalActive = nil
        }
        if case .text(let s)? = value("signer"), !s.isEmpty {
            self.signer = s
        } else {
            self.signer = nil
        }
        if case .bool(let p)? = value("signerPinned") {
            self.signerPinned = p
        } else {
            self.signerPinned = nil
        }
        self.acceptedAt = stamp("acceptedAt")
        self.signedAt = stamp("signedAt")
        if case .text(let o)? = value("origin"), !o.isEmpty {
            self.origin = o
        } else {
            self.origin = nil
        }
    }
}

/// What the agent said about its country-signing anchors, including the two
/// answers that are not a report at all.
///
/// The three cases are kept apart because collapsing any two of them makes a
/// claim the agent did not: "nothing is installed" is a statement about what
/// this computer trusts, and deriving it from a value that merely failed to
/// decode is the mirror image of the zeroed-report mistake this wire is built
/// to avoid — the agent clears its state rather than zeroing it for exactly
/// the same reason.
public enum CscaAnchorReport: Sendable, Equatable {
    /// The agent published the empty map that means nothing has been
    /// imported. A real, readable answer, and the only one that licenses
    /// telling a person that no anchors are installed.
    case nothingImported
    /// The agent published SOMETHING this build could not read — not a map,
    /// or a map without usable counts. A conforming agent does not produce
    /// this; a surface that renders it as `none` would still be converting a
    /// decode failure into a security claim.
    case unreadable
    /// A report that decoded.
    case held(CscaAnchorState)

    /// Classifies one raw config value.
    public init(cbor: CBORValue) {
        if case .map(let pairs) = cbor, pairs.isEmpty {
            self = .nothingImported
        } else if let state = CscaAnchorState(cbor: cbor) {
            self = .held(state)
        } else {
            self = .unreadable
        }
    }

    /// The decoded report, or nil in both of the cases that carry none. Only
    /// for callers that have already decided what the other two should say —
    /// it deliberately cannot tell them apart.
    public var state: CscaAnchorState? {
        if case .held(let state) = self { return state }
        return nil
    }
}

// MARK: - Credential wire enums (Credentials1 seam)

/// Client-side verb vocabulary for `ManagePin` — the closed CDDL
/// `cred-verb` set (`librescrs-agent.cddl`). The raw value IS the wire
/// token (`activate_pin` stays snake_case on the wire).
public enum CredentialVerb: String, Sendable, Equatable, CaseIterable {
    case change = "change"
    case unblock = "unblock"
    case activatePin = "activate_pin"
}

/// Outcome of a credential mutation, carried as `cred-result.outcome`.
/// Mirrors `LibreSCRS::Agent::CredentialOutcome` and CDDL `cred-outcome`
/// (`librescrs-agent.cddl`); the raw value IS the camelCase wire
/// token.
///
/// Wire tolerance: `cred-outcome` is a TEXT-token closed enum, exactly like
/// `SyncError` — an unrecognized token DEGRADES AT DECODE
/// (`parseCredResult` in `Messages.swift`) to `.unspecified` (the value
/// this wire already uses for "no meaningful outcome") instead of failing
/// the `cred-result` — and so the whole `op-result-ready` — closed
/// (`ClientCodec.h`'s tolerance table). The original wire token is not
/// retained on the degrade path.
public enum CredentialOutcome: String, Sendable, Equatable, CaseIterable {
    case unspecified = "unspecified"
    case ok = "ok"
    case userCancelled = "userCancelled"
    case missingFields = "missingFields"
    case invalidPin = "invalidPin"
    case blocked = "blocked"
    case pluginError = "pluginError"
    case unsupported = "unsupported"
    case keyActivationFailed = "keyActivationFailed"
    case cardRemoved = "cardRemoved"
    case entryExpired = "entryExpired"
}

/// Credential kind (`cred-record.kind`). Mirrors CDDL `cred-kind`
/// (`librescrs-agent.cddl`); the raw value IS the wire token.
///
/// Unlike every other enum in this package (which decode fail-closed),
/// the four record-token enums (`CredentialKind` / `CredentialState` /
/// `CredentialUnblockStyle` / `CredentialRecovery`) DEGRADE an
/// unrecognized token to `.unknown` via `init(token:)`. The wire
/// vocabulary itself reserves an `unknown` member as its "cannot
/// classify" value, and a record carrying one future token is still a
/// valid, displayable record — dropping a whole listing over one appended
/// token would be strictly worse than surfacing that record as unknown.
public enum CredentialKind: String, Sendable, Equatable, CaseIterable {
    case user = "user"
    case sign = "sign"
    case puk = "puk"
    case can = "can"
    case unknown = "unknown"

    /// Tolerant wire-token decode: unrecognized -> `.unknown` (see the
    /// type comment for why this enum family degrades).
    public init(token: String) {
        self = Self(rawValue: token) ?? .unknown
    }
}

/// Credential lifecycle state (`cred-record.state`). Mirrors CDDL
/// `cred-state` (`librescrs-agent.cddl`); the raw value IS the wire
/// token. Degrades unrecognized tokens to `.unknown` — see
/// `CredentialKind` for the rationale shared by this enum family.
public enum CredentialState: String, Sendable, Equatable, CaseIterable {
    case unknown = "unknown"
    case transport = "transport"
    case operational = "operational"
    case needsChange = "needsChange"
    case blocked = "blocked"

    /// Tolerant wire-token decode: unrecognized -> `.unknown`.
    public init(token: String) {
        self = Self(rawValue: token) ?? .unknown
    }
}

/// How an unblock behaves on this credential (`cred-record.unblockStyle`).
/// Mirrors CDDL `unblock-style` (`librescrs-agent.cddl`); the raw
/// value IS the wire token. Degrades unrecognized tokens to `.unknown` —
/// see `CredentialKind` for the rationale shared by this enum family.
public enum CredentialUnblockStyle: String, Sendable, Equatable, CaseIterable {
    case unknown = "unknown"
    case resetOnly = "resetOnly"
    case setsNewPin = "setsNewPin"
    case unblockAndChange = "unblockAndChange"

    /// Tolerant wire-token decode: unrecognized -> `.unknown`.
    public init(token: String) {
        self = Self(rawValue: token) ?? .unknown
    }
}

/// Recovery path once a credential is blocked (`cred-record.recovery`).
/// Mirrors CDDL `cred-recovery` (`librescrs-agent.cddl`); the raw
/// value IS the wire token. Degrades unrecognized tokens to `.unknown` —
/// see `CredentialKind` for the rationale shared by this enum family.
public enum CredentialRecovery: String, Sendable, Equatable, CaseIterable {
    case unknown = "unknown"
    case holderViaPuk = "holderViaPuk"
    case issuerProcess = "issuerProcess"
    case none = "none"

    /// Tolerant wire-token decode: unrecognized -> `.unknown`.
    public init(token: String) {
        self = Self(rawValue: token) ?? .unknown
    }
}

// MARK: - Value models

/// One reader-scoped state cell. Mirrors `LibreSCRS::Darwin::wire::ReaderState`
/// and CDDL `reader-state` (`librescrs-agent.cddl`).
public struct ReaderState: Sendable, Equatable {
    public let handle: String
    public let name: String
    public let hasCard: Bool
    public let card: String?

    public init(handle: String, name: String, hasCard: Bool, card: String? = nil) {
        self.handle = handle
        self.name = name
        self.hasCard = hasCard
        self.card = card
    }
}

/// One card-scoped state cell. Mirrors `LibreSCRS::Darwin::wire::CardState`
/// and CDDL `card-state` (`librescrs-agent.cddl`).
public struct CardState: Sendable, Equatable {
    public let handle: String
    public let reader: String
    public let caps: Capabilities
    public let preAuth: PreReadAuth

    public init(handle: String, reader: String, caps: Capabilities, preAuth: PreReadAuth) {
        self.handle = handle
        self.reader = reader
        self.caps = caps
        self.preAuth = preAuth
    }
}

/// One labeled certificate-field cell: `[labelKey, labelFallback, value]`
/// (`value` is always UTF-8 text on the certificate surface). Mirrors
/// `LibreSCRS::Darwin::wire::CertField` and CDDL `cert-field`
/// (`librescrs-agent.cddl`).
public struct CertField: Sendable, Equatable {
    public let labelKey: String
    public let labelFallback: String
    public let value: String

    public init(labelKey: String, labelFallback: String, value: String) {
        self.labelKey = labelKey
        self.labelFallback = labelFallback
        self.value = value
    }
}

/// Certificate metadata as the agent groups it for display: `group -> field
/// -> cell`. Mirrors `LibreSCRS::Darwin::wire::CertInfo` and CDDL
/// `cert-info` (`librescrs-agent.cddl`).
///
/// NOTE: this model has no flat scalar fields (`subjectCN`, `issuerCN`,
/// `notBefore`, `notAfter`, `usage?`, `ekus?`). The actual wire shape —
/// both the C++ `CertInfo` struct and the CDDL `cert-info` rule —
/// has no such flat fields; certificate metadata rides the grouped
/// `fields: group -> field -> [labelKey, labelFallback, value]` map plus
/// `keyUsageBits` / `ekus` / `chainSubjectCns` / `trustStatus`. This type
/// follows the wire structure verbatim (the wire contract is authoritative
/// where it differs from any flat-field sketch); the struct is named
/// `CertificateInfo`.
public struct CertificateInfo: Sendable, Equatable {
    public let certId: String
    public let signingCapable: Bool
    public let fields: [String: [String: CertField]]
    public let keyUsageBits: UInt32
    public let ekus: [String]
    public let chainSubjectCns: [String]
    public let trustStatus: UInt32

    public init(
        certId: String, signingCapable: Bool, fields: [String: [String: CertField]],
        keyUsageBits: UInt32, ekus: [String], chainSubjectCns: [String], trustStatus: UInt32
    ) {
        self.certId = certId
        self.signingCapable = signingCapable
        self.fields = fields
        self.keyUsageBits = keyUsageBits
        self.ekus = ekus
        self.chainSubjectCns = chainSubjectCns
        self.trustStatus = trustStatus
    }
}

/// A PAdES visible-signature appearance for `SignOptions.visualSignature`.
/// Mirrors `LibreSCRS::Darwin::wire::VisualSignatureOpts` and CDDL
/// `visual-sig-opts` field-for-field — all six are required together (only
/// the outer `SignOptions.visualSignature` is itself optional). `page` is
/// 0-based; `x`/`y`/`width`/`height` are PDF user units (float64 on the
/// wire); `width`/`height` must be positive. Rejected by the agent at
/// method entry on any `format` other than `"pades"`.
public struct VisualSignatureOptions: Sendable, Equatable {
    public let page: UInt64
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let text: String

    public init(page: UInt64, x: Double, y: Double, width: Double, height: Double, text: String) {
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
    }
}

/// Signature container format a client may REQUEST. Raw values ARE the wire
/// tokens: the agent's closed set — enforced by
/// `SignatureParams::isKnownFormat` — is lowercase-only, which is why this is
/// an enum and not a free string. `auto` asks the agent to sniff the format
/// from the document's leading bytes; it is the deferral sentinel the
/// client sends, not itself a member of `isKnownFormat`'s set. Request-only:
/// `SignMeta.format` reports a resolved format and stays a `String`, so an
/// unknown future token degrades at decode instead of failing the frame.
public enum SignatureFormat: String, Sendable, CaseIterable {
    case pades, cades, xades, jades, asice, auto
}

/// eIDAS AdES conformance level a client may REQUEST, enforced agent-side as
/// a closed set by `SignatureParams::isKnownLevel`. `auto` is the deferral
/// sentinel the client sends for the frontend to resolve against the agent's
/// configured `DefaultLevel`, including that value's upgrade to b-t when a
/// timestamp authority is configured. Request-only, same reasoning as above.
public enum SignatureLevel: String, Sendable, CaseIterable {
    case bB = "b-b", bT = "b-t", bLT = "b-lt", bLTA = "b-lta", auto
}

/// Signature packaging relative to the signed document, enforced agent-side
/// as a closed set by `SignatureParams::isKnownPackaging`. `enveloping` is
/// deliberately absent: it exists nowhere below the C++ agent client — not
/// in `isKnownPackaging`, not in LibreMiddleware's `PackagingMode`, not in
/// the signing engine itself. `auto` is the deferral sentinel that resolves
/// per format.
public enum Packaging: String, Sendable, CaseIterable {
    case enveloped, detached, auto
}

/// `Card1.Sign` request options. `format`/`level`/`packaging` are required;
/// the rest are per-sign chrome. Mirrors `LibreSCRS::Darwin::wire::SignOpts`
/// and CDDL `sign-opts` (`librescrs-agent.cddl`).
///
/// `tsaUrl` overrides the agent's configured TSA (Config1's `TsaUrls`/
/// `LastTsaUrl`) for THIS sign only — https + non-empty host, and only
/// meaningful for the timestamped/long-term family; paired with level
/// `"b-b"` it is a method-entry rejection, not a silent no-op. `nil` uses
/// the configured default. `visualSignature` attaches a PAdES visible-
/// signature appearance; rejected at method entry on any other format. Both
/// are gated behind their own HelloAck-equivalent feature tokens
/// (`"tsa-url"` / `"visual-sign"`, `Manager1.Features`/`HelloAck.features`).
public struct SignOptions: Sendable, Equatable {
    public let format: SignatureFormat
    public let level: SignatureLevel
    public let packaging: Packaging
    /// Consent to sign with an expired certificate — honored only at the
    /// baseline level: the agent proceeds on expired + `.bB` + this consent,
    /// but blocks on expired + the qualified family (`.bT`/`.bLT`/`.bLTA`)
    /// regardless of it. An agent that resolves `.auto` to a qualified level
    /// therefore voids this consent — a caller who wants it honored must send
    /// an explicit `.bB`, never `.auto`.
    public let allowExpired: Bool?
    public let displayName: String?
    public let reason: String?
    public let location: String?
    /// See the type doc above for the general `tsaUrl` contract. Pairing
    /// `tsaUrl` with `.auto` counts toward the agent's own "is a timestamp
    /// authority available" decision: against a current agent, a per-request
    /// `tsaUrl` lifts a defaulted `b-b` to `b-t` the same way a configured
    /// `TsaUrls` would, so the pairing is accepted. Only against an agent
    /// that predates that frontend fix does this per-request value not
    /// count, so `.auto` can still resolve to `b-b` and the pairing is then
    /// rejected — exactly as `tsaUrl` alongside an EXPLICIT `"b-b"` still is,
    /// on every agent version.
    public let tsaUrl: String?
    public let visualSignature: VisualSignatureOptions?

    public init(
        format: SignatureFormat, level: SignatureLevel, packaging: Packaging,
        allowExpired: Bool? = nil, displayName: String? = nil, reason: String? = nil, location: String? = nil,
        tsaUrl: String? = nil, visualSignature: VisualSignatureOptions? = nil
    ) {
        self.format = format
        self.level = level
        self.packaging = packaging
        self.allowExpired = allowExpired
        self.displayName = displayName
        self.reason = reason
        self.location = location
        self.tsaUrl = tsaUrl
        self.visualSignature = visualSignature
    }
}

/// Metadata describing a completed signature. Mirrors
/// `LibreSCRS::Darwin::wire::SignMeta` and CDDL `sign-meta`
/// (`librescrs-agent.cddl`).
public struct SignMeta: Sendable, Equatable {
    public let format: String
    public let level: String
    public let tsaUsed: Bool
    public let chainComplete: Bool

    public init(format: String, level: String, tsaUsed: Bool, chainComplete: Bool) {
        self.format = format
        self.level = level
        self.tsaUsed = tsaUsed
        self.chainComplete = chainComplete
    }
}

/// A signing op-result payload: the signed artifact rides SCM_RIGHTS and is
/// referenced here by fd-index only (resolution to a real fd is a later
/// task's concern). Mirrors `LibreSCRS::Darwin::wire::SignResult` and CDDL
/// `sign-result` (`librescrs-agent.cddl`).
public struct SignResult: Sendable, Equatable {
    public let artifact: UInt64 // fd-index into the frame's SCM_RIGHTS vector
    public let meta: SignMeta

    public init(artifact: UInt64, meta: SignMeta) {
        self.artifact = artifact
        self.meta = meta
    }
}

/// One identity-field cell's value: `tstr` for `text`/`date` fields, `bstr`
/// for `binary` fields. Mirrors the `value` arm of `IdentityField` and CDDL
/// `id-field`'s `value: tstr / bstr` (`librescrs-agent.cddl`).
public enum IdentityFieldValue: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// One labeled identity-field cell: `[labelKey, labelFallback, type,
/// value]`. Mirrors `LibreSCRS::Darwin::wire::IdentityField` and CDDL
/// `id-field` (`librescrs-agent.cddl`).
public struct IdentityField: Sendable, Equatable {
    public let labelKey: String
    public let labelFallback: String
    public let type: String // "text" | "date" | "binary"
    public let value: IdentityFieldValue

    public init(labelKey: String, labelFallback: String, type: String, value: IdentityFieldValue) {
        self.labelKey = labelKey
        self.labelFallback = labelFallback
        self.type = type
        self.value = value
    }
}

/// `ReadIdentity` op-result payload: `group -> field -> cell`. Mirrors
/// `LibreSCRS::Darwin::wire::IdentityResult` and CDDL `identity-result`
/// (`librescrs-agent.cddl`).
public struct IdentityResult: Sendable, Equatable {
    public let fields: [String: [String: IdentityField]]

    public init(fields: [String: [String: IdentityField]]) {
        self.fields = fields
    }
}

/// One photo item: `key` is `"group:field"`; `fd` is an fd-index into the
/// frame's SCM_RIGHTS vector (resolution to a real fd is a later task's
/// concern). Mirrors `LibreSCRS::Darwin::wire::PhotoItem` and the
/// `photo-result` array element (`librescrs-agent.cddl`).
public struct PhotoItem: Sendable, Equatable {
    public let key: String
    public let fd: UInt64

    public init(key: String, fd: UInt64) {
        self.key = key
        self.fd = fd
    }
}

/// `GetPhoto` op-result payload. Mirrors
/// `LibreSCRS::Darwin::wire::PhotoResult` and CDDL `photo-result`
/// (`librescrs-agent.cddl`).
public struct PhotoResult: Sendable, Equatable {
    public let photos: [PhotoItem]

    public init(photos: [PhotoItem]) {
        self.photos = photos
    }
}

/// One credential (PIN/PUK/CAN) record from a credentials listing.
/// Mirrors `LibreSCRS::Agent::CredentialRecord` and CDDL `cred-record`
/// (`librescrs-agent.cddl`) — 23 camelCase wire keys: the wire's
/// optional keys are optionals here; the always-written booleans are
/// non-optional. `id` is the agent-synthesized handle a `ManagePin`
/// addresses (this wire never carries a secret).
public struct CredentialRecord: Sendable, Equatable {
    public let id: String
    public let label: String
    public let kind: CredentialKind
    public let state: CredentialState
    public let retriesLeft: UInt32?
    public let retriesMax: UInt32?
    public let usesLeft: UInt32?
    public let usesMax: UInt32?
    public let unblocksLeft: UInt32?
    public let minLength: UInt32?
    public let maxLength: UInt32?
    public let canChange: Bool
    public let unblockable: Bool
    public let unblockStyle: CredentialUnblockStyle
    public let activatable: Bool
    public let keyActivationPending: Bool
    public let keyActivatable: Bool
    public let recovery: CredentialRecovery
    public let probeSafe: Bool
    public let blockedGuidanceKey: String?
    public let blockedGuidanceFallback: String?
    public let keyActivationGuidanceKey: String?
    public let keyActivationGuidanceFallback: String?

    public init(
        id: String, label: String, kind: CredentialKind, state: CredentialState,
        retriesLeft: UInt32? = nil, retriesMax: UInt32? = nil, usesLeft: UInt32? = nil,
        usesMax: UInt32? = nil,
        unblocksLeft: UInt32? = nil, minLength: UInt32? = nil, maxLength: UInt32? = nil,
        canChange: Bool, unblockable: Bool, unblockStyle: CredentialUnblockStyle,
        activatable: Bool, keyActivationPending: Bool, keyActivatable: Bool,
        recovery: CredentialRecovery, probeSafe: Bool,
        blockedGuidanceKey: String? = nil, blockedGuidanceFallback: String? = nil,
        keyActivationGuidanceKey: String? = nil, keyActivationGuidanceFallback: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.state = state
        self.retriesLeft = retriesLeft
        self.retriesMax = retriesMax
        self.usesLeft = usesLeft
        self.usesMax = usesMax
        self.unblocksLeft = unblocksLeft
        self.minLength = minLength
        self.maxLength = maxLength
        self.canChange = canChange
        self.unblockable = unblockable
        self.unblockStyle = unblockStyle
        self.activatable = activatable
        self.keyActivationPending = keyActivationPending
        self.keyActivatable = keyActivatable
        self.recovery = recovery
        self.probeSafe = probeSafe
        self.blockedGuidanceKey = blockedGuidanceKey
        self.blockedGuidanceFallback = blockedGuidanceFallback
        self.keyActivationGuidanceKey = keyActivationGuidanceKey
        self.keyActivationGuidanceFallback = keyActivationGuidanceFallback
    }
}

/// Uniform result of a credential mutation (and the `Ok` result of a
/// listing). Mirrors `LibreSCRS::Agent::CredentialOpResult` and CDDL
/// `cred-result` (`librescrs-agent.cddl`). `pinActivated` /
/// `keyActivated` are populated for the `activate_pin` bring-up
/// continuation and for `ActivateSigningKey` (partial bring-up =
/// `pinActivated == true`, `keyActivated == false`, outcome
/// `.keyActivationFailed`).
public struct CredentialResult: Sendable, Equatable {
    public let outcome: CredentialOutcome
    public let retriesLeft: UInt32?
    public let blocked: Bool
    public let pinActivated: Bool?
    public let keyActivated: Bool?

    public init(
        outcome: CredentialOutcome, retriesLeft: UInt32? = nil, blocked: Bool,
        pinActivated: Bool? = nil, keyActivated: Bool? = nil
    ) {
        self.outcome = outcome
        self.retriesLeft = retriesLeft
        self.blocked = blocked
        self.pinActivated = pinActivated
        self.keyActivated = keyActivated
    }
}

/// `Credentials` op-result payload: the mutation/list result plus the
/// (possibly empty) record listing. Mirrors
/// `LibreSCRS::Darwin::wire::CredentialsResult` and CDDL
/// `credentials-result` (`librescrs-agent.cddl`). A mutation's
/// `records` is always `[]`; a listing emits this payload only when it
/// completes Ok.
public struct CredentialsPayload: Sendable, Equatable {
    public let result: CredentialResult
    public let records: [CredentialRecord]

    public init(result: CredentialResult, records: [CredentialRecord]) {
        self.result = result
        self.records = records
    }
}

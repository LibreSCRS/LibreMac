// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

// Value types for the LibreMac agent wire protocol. These mirror the
// LibreDarwin agent's `LibreSCRS::Darwin::wire` C++ types (`Messages.h`) and
// the reconciled CDDL contract (`agent/wire/librescrs-agent.cddl`) that both
// implementations round-trip against. Enum raw values are wire-significant
// and locked to the upstream numbering; never renumber existing cases.

// MARK: - Wire-mirrored enums

/// Stable agent-side error taxonomy, carried as the numeric `code` arm of a
/// reply's `err` field and as `OpFinished.code`. Mirrors
/// `LibreSCRS::Agent::ErrorCode` (LibreAgent) and the CDDL `error-code`
/// socket (`librescrs-agent.cddl:43-48`). 20 values, append-only — never
/// renumber.
///
/// Wire tolerance: `error-code` is wire-frozen append-only, so a newer agent
/// may send a code past `invalidDocument` — this build simply does not have
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
        case .unknown(let v): return v
        }
    }

    /// `true` for every case except `.unknown` — a future value this build
    /// does not have a name for yet. See the type doc comment.
    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

extension ErrorCode: CaseIterable {
    /// Hand-rolled (associated-value cases forbid synthesis): the 20 NAMED
    /// cases only. `.unknown` is not a discrete case to enumerate — it is
    /// an open-ended family of raw values — so it is deliberately excluded;
    /// `ErrorCopyTests.taxonomyHasTwentyValues` gates this count.
    public static var allCases: [ErrorCode] {
        [
            .none, .cardRemoved, .credentialWrong, .credentialBlocked, .communicationError,
            .parseError, .unsupportedCard, .authFailed, .prompterError, .capabilityMissing,
            .watchdogTimeout, .keyNotFound, .keyAmbiguous, .certExpiredBlocked, .chainIncomplete,
            .tsaUnreachable, .signingEngineError, .rateLimited, .engineUnavailable, .invalidDocument,
        ]
    }
}

/// Named synchronous-method errors (D-Bus `Error.*` names), carried as the
/// string `name` arm of a reply's `err` field. Distinct from the numeric
/// `ErrorCode` — one or the other, never both (`err-info`,
/// `librescrs-agent.cddl:97,101-105`). The raw value IS the wire string,
/// mirroring the agent's sync-error names. 18 values.
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
}

/// `Operation1` progress phase. Mirrors
/// `LibreSCRS::Agent::Operations::OperationPhase` (LibreAgent) and CDDL
/// `op-phase` (`librescrs-agent.cddl:39-40`). Append-only.
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
}

/// Terminal `Operation1.Finished` status. Mirrors
/// `LibreSCRS::Agent::Operations::OperationStatus` (LibreAgent) and CDDL
/// `op-status` (`librescrs-agent.cddl:41`).
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
}

/// Socket-only lifecycle vocabulary — no upstream core enum, macOS-specific
/// (system sleep / screen lock / session switch / shutdown quiesce). Mirrors
/// `LibreSCRS::Darwin::wire::QuiesceReason` (LibreDarwin) and CDDL
/// `quiesce-reason` (`librescrs-agent.cddl:150`).
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
}

/// Pre-read unlock mechanism for travel-document-style cards. Mirrors
/// `LibreSCRS::Auth::PreReadAuthMethod` (LibreMiddleware
/// `include/LibreSCRS/Auth/AuthRequirement.h` — `None`/`Mrz`/`Can`)
/// and CDDL `pre-read-auth` (`librescrs-agent.cddl:38`).
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
}

/// Card capability bitmask carried as `CardState.caps` (a raw `uint32` on
/// the wire — see the C++ `CardState::caps` comment in the LibreDarwin
/// agent's wire types). Bit positions mirror the CDDL `capability-bit`
/// group (`librescrs-agent.cddl:36-37`); there is no dedicated upstream C++
/// enum for this bitmask today.
public struct Capabilities: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let pki = Capabilities(rawValue: 1 << 0)
    public static let identityData = Capabilities(rawValue: 1 << 1)
    public static let emrtdCrypto = Capabilities(rawValue: 1 << 2)
    public static let pinManagement = Capabilities(rawValue: 1 << 3)
}

// MARK: - Credential wire enums (Credentials1 seam)

/// Client-side verb vocabulary for `ManagePin` — the closed CDDL
/// `cred-verb` set (`librescrs-agent.cddl:88`). The raw value IS the wire
/// token (`activate_pin` stays snake_case on the wire).
public enum CredentialVerb: String, Sendable, Equatable, CaseIterable {
    case change = "change"
    case unblock = "unblock"
    case activatePin = "activate_pin"
}

/// Outcome of a credential mutation, carried as `cred-result.outcome`.
/// Mirrors `LibreSCRS::Agent::CredentialOutcome` and CDDL `cred-outcome`
/// (`librescrs-agent.cddl:215-217`); the raw value IS the camelCase wire
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
}

/// Credential kind (`cred-record.kind`). Mirrors CDDL `cred-kind`
/// (`librescrs-agent.cddl:227`); the raw value IS the wire token.
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
/// `cred-state` (`librescrs-agent.cddl:228`); the raw value IS the wire
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
/// Mirrors CDDL `unblock-style` (`librescrs-agent.cddl:229`); the raw
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
/// Mirrors CDDL `cred-recovery` (`librescrs-agent.cddl:230`); the raw
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
/// and CDDL `reader-state` (`librescrs-agent.cddl:120`).
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
/// and CDDL `card-state` (`librescrs-agent.cddl:121`).
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
/// (`librescrs-agent.cddl:128`).
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
/// `cert-info` (`librescrs-agent.cddl:125-127`).
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

/// `Card1.Sign` request options. `format`/`level`/`packaging` are required;
/// the rest are per-sign chrome. Mirrors `LibreSCRS::Darwin::wire::SignOpts`
/// and CDDL `sign-opts` (`librescrs-agent.cddl:79-80`).
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
    public let format: String
    public let level: String
    public let packaging: String
    public let allowExpired: Bool?
    public let displayName: String?
    public let reason: String?
    public let location: String?
    public let tsaUrl: String?
    public let visualSignature: VisualSignatureOptions?

    public init(
        format: String, level: String, packaging: String,
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
/// (`librescrs-agent.cddl:161`).
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
/// `sign-result` (`librescrs-agent.cddl:160`).
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
/// `id-field`'s `value: tstr / bstr` (`librescrs-agent.cddl:157`).
public enum IdentityFieldValue: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// One labeled identity-field cell: `[labelKey, labelFallback, type,
/// value]`. Mirrors `LibreSCRS::Darwin::wire::IdentityField` and CDDL
/// `id-field` (`librescrs-agent.cddl:157`).
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
/// (`librescrs-agent.cddl:156`).
public struct IdentityResult: Sendable, Equatable {
    public let fields: [String: [String: IdentityField]]

    public init(fields: [String: [String: IdentityField]]) {
        self.fields = fields
    }
}

/// One photo item: `key` is `"group:field"`; `fd` is an fd-index into the
/// frame's SCM_RIGHTS vector (resolution to a real fd is a later task's
/// concern). Mirrors `LibreSCRS::Darwin::wire::PhotoItem` and the
/// `photo-result` array element (`librescrs-agent.cddl:158`).
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
/// (`librescrs-agent.cddl:158`).
public struct PhotoResult: Sendable, Equatable {
    public let photos: [PhotoItem]

    public init(photos: [PhotoItem]) {
        self.photos = photos
    }
}

/// One credential (PIN/PUK/CAN) record from a credentials listing.
/// Mirrors `LibreSCRS::Agent::CredentialRecord` and CDDL `cred-record`
/// (`librescrs-agent.cddl:218-226`) — 23 camelCase wire keys: the wire's
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
/// `cred-result` (`librescrs-agent.cddl:213-214`). `pinActivated` /
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
/// `credentials-result` (`librescrs-agent.cddl:211-212`). A mutation's
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

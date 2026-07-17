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
public enum ErrorCode: UInt32, Sendable, Equatable, CaseIterable {
    case none = 0
    case cardRemoved = 1
    case credentialWrong = 2
    case credentialBlocked = 3
    case communicationError = 4
    case parseError = 5
    case unsupportedCard = 6
    case authFailed = 7
    case prompterError = 8
    case capabilityMissing = 9
    case watchdogTimeout = 10
    case keyNotFound = 11
    case keyAmbiguous = 12
    case certExpiredBlocked = 13
    case chainIncomplete = 14
    case tsaUnreachable = 15
    case signingEngineError = 16
    case rateLimited = 17
    case engineUnavailable = 18
    case invalidDocument = 19
}

/// Named synchronous-method errors (D-Bus `Error.*` names), carried as the
/// string `name` arm of a reply's `err` field. Distinct from the numeric
/// `ErrorCode` — one or the other, never both (`err-info`,
/// `librescrs-agent.cddl:97,101-105`). The raw value IS the wire string,
/// mirroring the agent's sync-error names. 15 values.
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
}

/// `Operation1` progress phase. Mirrors
/// `LibreSCRS::Agent::Operations::OperationPhase` (LibreAgent) and CDDL
/// `op-phase` (`librescrs-agent.cddl:39-40`). Append-only.
public enum OperationPhase: UInt32, Sendable, Equatable, CaseIterable {
    case created = 0
    case connecting = 1
    case awaitingConsent = 2
    case authenticating = 3
    case reading = 4
    case signing = 5
    case timestamping = 6
    case done = 7
}

/// Terminal `Operation1.Finished` status. Mirrors
/// `LibreSCRS::Agent::Operations::OperationStatus` (LibreAgent) and CDDL
/// `op-status` (`librescrs-agent.cddl:41`).
public enum OperationStatus: UInt32, Sendable, Equatable, CaseIterable {
    case ok = 0
    case cancelled = 1
    case error = 2
}

/// Socket-only lifecycle vocabulary — no upstream core enum, macOS-specific
/// (system sleep / screen lock / session switch / shutdown quiesce). Mirrors
/// `LibreSCRS::Darwin::wire::QuiesceReason` (LibreDarwin) and CDDL
/// `quiesce-reason` (`librescrs-agent.cddl:150`).
public enum QuiesceReason: UInt32, Sendable, Equatable, CaseIterable {
    case systemSleep = 0
    case screenLocked = 1
    case sessionInactive = 2
    case shutdown = 3
}

/// Pre-read unlock mechanism for travel-document-style cards. Mirrors
/// `LibreSCRS::Auth::PreReadAuthMethod` (LibreMiddleware
/// `include/LibreSCRS/Auth/AuthRequirement.h` — `None`/`BacMrz`/`PaceCan`)
/// and CDDL `pre-read-auth` (`librescrs-agent.cddl:38`).
public enum PreReadAuth: UInt32, Sendable, Equatable, CaseIterable {
    case none = 0
    case bacMrz = 1
    case paceCan = 2
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

/// `Card1.Sign` request options. `format`/`level`/`packaging` are required;
/// the rest are per-sign chrome. Mirrors `LibreSCRS::Darwin::wire::SignOpts`
/// and CDDL `sign-opts` (`librescrs-agent.cddl:79-80`).
///
/// NOTE: there is NO `tsa` field on `sign-opts`, despite a `{format,level,
/// packaging,tsa?}` shape being an easy first guess. The CDDL is explicit
/// that there is NO `tsa` field on `sign-opts` — "the TSA is Config1-owned
/// (TsaUrls/LastTsaUrl), not a per-sign option"
/// (`librescrs-agent.cddl:78`) — and the C++ `SignOpts` struct has no `tsa`
/// member. This type follows the wire structure verbatim: the optional
/// fields are `allowExpired`, `displayName`, `reason`, `location`.
public struct SignOptions: Sendable, Equatable {
    public let format: String
    public let level: String
    public let packaging: String
    public let allowExpired: Bool?
    public let displayName: String?
    public let reason: String?
    public let location: String?

    public init(
        format: String, level: String, packaging: String,
        allowExpired: Bool? = nil, displayName: String? = nil, reason: String? = nil, location: String? = nil
    ) {
        self.format = format
        self.level = level
        self.packaging = packaging
        self.allowExpired = allowExpired
        self.displayName = displayName
        self.reason = reason
        self.location = location
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

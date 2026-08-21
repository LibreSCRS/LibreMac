// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Client-side mapping of the agent's stable `ErrorCode` taxonomy to a
// localized, user-facing string: localized copy per code, falling back to the
// agent's message for unmapped codes. The bulk of copy originates in the agent
// as a `LocalizedText` msgKey/msgFallback pair on the finished operation — the
// client renders that, it does not invent copy. This maps the small set of
// client-synchronous codes to a localized message, falling back to the
// agent-provided `msgFallback` for anything not localized here (and for
// `.none`). Named sync errors get the same treatment: the five credential
// entry errors carry dedicated copy; every other name renders as a
// communication failure.

import LibreMacAgentClient
import LibreMacShared

/// Single source of client-side error copy.
public enum ErrorCopy {

    /// The localized `LocalizedText` for a code the client phrases itself, or
    /// `nil` for `.none` / any code deferred to the agent's `msgFallback`.
    /// Split out from `message(...)` so a test can assert the 20-value
    /// coverage and the fallback boundary directly.
    public static func localizedText(for code: ErrorCode) -> LocalizedText? {
        switch code {
        case .none:
            return nil
        case .cardRemoved:
            return text("libremac_error_card_removed",
                        "The card was removed before the operation finished.")
        case .credentialWrong:
            return text("libremac_error_credential_wrong",
                        "The PIN or access code entered was incorrect.")
        case .credentialBlocked:
            return text("libremac_error_credential_blocked",
                        "The card credential is blocked. Unblock it before retrying.")
        case .communicationError:
            return communicationCopy
        case .parseError:
            return text("libremac_error_parse",
                        "The data read from the card could not be interpreted.")
        case .unsupportedCard:
            return text("libremac_error_unsupported_card",
                        "This card is not supported.")
        case .authFailed:
            return text("libremac_error_auth_failed",
                        "Authentication with the card failed.")
        case .prompterError:
            return text("libremac_error_prompter",
                        "The secure entry prompt could not be shown.")
        case .capabilityMissing:
            return text("libremac_error_capability_missing",
                        "This card does not support the requested operation.")
        case .watchdogTimeout:
            return text("libremac_error_watchdog_timeout",
                        "The operation timed out.")
        case .keyNotFound:
            return text("libremac_error_key_not_found",
                        "The selected certificate could not be found on the card.")
        case .keyAmbiguous:
            return text("libremac_error_key_ambiguous",
                        "More than one key matched the selection.")
        case .certExpiredBlocked:
            return text("libremac_error_cert_expired",
                        "The signing certificate has expired.")
        case .chainIncomplete:
            return text("libremac_error_chain_incomplete",
                        "The certificate chain could not be completed.")
        case .tsaUnreachable:
            return text("libremac_error_tsa_unreachable",
                        "The timestamp authority is unreachable.")
        case .signingEngineError:
            return text("libremac_error_signing_engine",
                        "The signing engine reported an error.")
        case .rateLimited:
            return text("libremac_error_rate_limited",
                        "Too many signing requests. Try again shortly.")
        case .engineUnavailable:
            return text("libremac_error_engine_unavailable",
                        "The signing engine could not be loaded. Check that LibreSCRS is installed correctly.")
        case .invalidDocument:
            return text("libremac_error_invalid_document",
                        "The document you tried to sign is invalid or unreadable. Check the file.")
        case .entryExpired:
            return text("libremac_error_entry_expired",
                        "The entry window closed before a code was entered. Try again.")
        case .unknown:
            // Wire tolerance: a code this build does not have a name for
            // yet (wire-frozen append-only `ErrorCode`) is opaque
            // display/log data, same posture as every code before this
            // policy existed — defer to the agent's own `msgFallback`,
            // exactly like `.none`.
            return nil
        }
    }

    /// The localized copy for a named sync error surfaced by the credentials
    /// request gates. The five credential entry errors — capability
    /// (`UnsupportedOnThisCard`), validation (`UnknownCredential`,
    /// `InvalidRequest`), authorization (`NotAuthorized`) and rate limiting
    /// (`RateLimited`) — each carry dedicated copy; every OTHER name keeps
    /// the pre-existing client posture of rendering as a communication
    /// failure. Exhaustive over `SyncError` (no `default`) so an appended
    /// wire name forces a copy decision here.
    public static func localizedText(for error: SyncError) -> LocalizedText {
        switch error {
        case .unsupportedOnThisCard:
            return text("libremac_credentials_err_unsupported",
                        "Credential management is not supported on this card.")
        case .notAuthorized:
            return text("libremac_credentials_err_not_authorized",
                        "You are not authorized to manage card credentials.")
        case .rateLimited:
            return text("libremac_credentials_err_rate_limited",
                        "Too many attempts. Try again shortly.")
        case .unknownCredential:
            return text("libremac_credentials_err_unknown_credential",
                        "The selected credential no longer exists on the card.")
        case .invalidRequest:
            return text("libremac_credentials_err_invalid_request",
                        "The request is not valid for this credential.")
        case .unknownCard, .keyNotFound, .userNotLoggedIn, .unknownConfigKey,
             .readOnlyConfig, .invalidConfigValue, .unsupportedProtocol,
             .authFailed, .communicationError, .notSupported,
             .unsupportedSignatureParameter, .inputTooLarge, .noResult:
            return communicationCopy
        }
    }

    /// Resolved user-facing message for a terminal operation outcome. Uses the
    /// client-localized copy when this code has one; otherwise the agent's
    /// authored `msgFallback` (which is non-empty by the operation contract).
    @MainActor
    public static func message(for code: ErrorCode, msgFallback: String) -> String {
        if let localized = localizedText(for: code) {
            return AppLocalization.shared.resolve(localized)
        }
        return msgFallback
    }

    /// Shared by the `ErrorCode` table and the sync-error fallback arm.
    private static let communicationCopy = LocalizedText(
        key: "libremac_error_communication",
        defaultText: "Communication with the card reader failed.")

    private static func text(_ key: String, _ fallback: String) -> LocalizedText {
        LocalizedText(key: key, defaultText: fallback)
    }
}

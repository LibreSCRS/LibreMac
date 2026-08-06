// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Host-side publication of the card's Keychain identities, in step with card
// presence. Only the host app (the appex's container app) may populate
// `TKTokenDriver.Configuration.driverConfigurations` — this is that
// publisher: one `TKTokenKeychainCertificate` + `TKTokenKeychainKey` token
// configuration per signing cert on insert, all of them cleared on removal
// (remove-on-eject).
//
// Trust is re-derived here, not assumed from the caller: a cert is only
// published when SHA-256(DER) equals the claimed `certId` AND the DER parses
// as a valid `SecCertificate`. `certId`/`objectID` are the SHA-256 hex of the
// certificate DER, matching the agent's own hashing so SIGN objectIDs line
// up on both sides of the bridge.

import CryptoKit
import CryptoTokenKit
import Foundation
import LibreMacShared
import Security
import os

/// A signing certificate eligible for Keychain publication, as reported by
/// the card-presence pipeline.
public struct PublishableCert: Equatable, Sendable {
    /// SHA-256 hex of `der`, as computed by the reporting layer. Re-verified
    /// against `der` before publication — never trusted as-is.
    public let certId: String
    /// The raw certificate bytes, DER-encoded, unmodified from the card.
    public let der: Data
    /// Qualified-certificate flag; gates publication behind
    /// `LIBRESCRS_ENABLE_QES_KEYCHAIN` (default off).
    public let isQualified: Bool

    public init(certId: String, der: Data, isQualified: Bool) {
        self.certId = certId
        self.der = der
        self.isQualified = isQualified
    }
}

/// Seam over `TKTokenDriver.Configuration` so the publish/remove logic is
/// unit-testable without a running `ctkd` and a registered driver.
public protocol TokenConfigStore {
    /// Publishes one token configuration under `instanceID` with the given
    /// `keychainItems` (a `TKTokenKeychainCertificate` + `TKTokenKeychainKey`
    /// pair in production).
    func addToken(instanceID: String, items: [Any])
    /// Removes the token configuration for `instanceID`, if any.
    func removeToken(instanceID: String)
    /// Removes every token configuration currently registered under this
    /// driver class, independent of what any caller's in-memory bookkeeping
    /// believes is published. Used to recycle stale state left over from a
    /// prior process (a fresh caller has no bookkeeping to go by at all).
    func clearAll()
}

/// Production `TokenConfigStore`: mutates `driverConfigurations` for this
/// extension's driver class id. Only valid when called from the host app —
/// the appex's container app is the sole process that can populate
/// `driverConfigurations`.
public final class DriverConfigStore: TokenConfigStore {
    private let classID: String

    public init(classID: String) {
        self.classID = classID
    }

    private var cfg: TKTokenDriver.Configuration? {
        guard let cfg = TKTokenDriver.Configuration.driverConfigurations[classID] else {
            // No entry for `classID` means the driver class is misconfigured
            // (typo'd/renamed id, or the appex is not registered). Fail
            // loudly and publish nothing — publishing under whatever other
            // configuration happens to exist would mask the misconfiguration.
            Logger.card.fault("no driver configuration for class \(self.classID, privacy: .public); token publication skipped")
            return nil
        }
        return cfg
    }

    public func addToken(instanceID: String, items: [Any]) {
        guard let cfg else { return }
        // The seam is untyped `[Any]` so callers/tests never need to import
        // CryptoTokenKit; production callers only ever pass
        // `TKTokenKeychainCertificate`/`TKTokenKeychainKey`, both
        // `TKTokenKeychainItem` subclasses, so this cast is expected to
        // always succeed.
        guard let keychainItems = items as? [TKTokenKeychainItem] else { return }
        let tokenConfiguration = cfg.addTokenConfiguration(for: instanceID)
        tokenConfiguration.keychainItems = keychainItems
    }

    public func removeToken(instanceID: String) {
        cfg?.removeTokenConfiguration(for: instanceID)
    }

    public func clearAll() {
        guard let cfg else { return }
        // `tokenConfigurations` is a `readonly, copy` property: the `keys`
        // snapshot below is unaffected by the removals that follow, so
        // iterating and mutating in the same loop is safe.
        for instanceID in cfg.tokenConfigurations.keys {
            cfg.removeTokenConfiguration(for: instanceID)
        }
    }
}

/// Publishes/removes the card's Keychain identities in step with card
/// presence. Not `Sendable`: every entry point (`onCardPresent`,
/// `onCardRemoved`, `reregisterOnLaunch`) is driven synchronously from the
/// host's card-presence pipeline on a single isolation domain.
public final class TokenIdentityRegistrar {
    private let store: TokenConfigStore
    private var published: Set<String> = []

    public init(store: TokenConfigStore) {
        self.store = store
    }

    private func instanceID(_ certId: String) -> String {
        "librescrs-\(certId)"
    }

    /// Publishes one token configuration per cert in `certs` that passes the
    /// SHA-256 + DER-parse gate. Certs that fail either check are silently
    /// skipped — never published, never crash the presence pipeline.
    public func onCardPresent(certs: [PublishableCert]) {
        for cert in certs {
            // Qualified-certificate publication is gated separately behind
            // an explicit opt-in; unqualified certs are always eligible.
            if cert.isQualified && !Self.qesKeychainEnabled { continue }

            let computed = SHA256.hash(data: cert.der).map { String(format: "%02x", $0) }.joined()
            guard computed == cert.certId else { continue }
            guard let secCert = SecCertificateCreateWithData(nil, cert.der as CFData) else { continue }

            let objectID = cert.certId
            guard let keychainCert = TKTokenKeychainCertificate(certificate: secCert, objectID: objectID),
                let keychainKey = TKTokenKeychainKey(certificate: secCert, objectID: objectID)
            else { continue }
            keychainKey.canSign = true
            // Attach a constraint on signData so a sign triggers
            // beginAuthForOperation: (the token extension's auth bridge).
            keychainKey.constraints = [NSNumber(value: TKTokenOperation.signData.rawValue): ["authID": objectID]]

            let iid = instanceID(cert.certId)
            store.addToken(instanceID: iid, items: [keychainCert, keychainKey])
            published.insert(iid)
        }
    }

    /// Clears every token configuration published by this registrar
    /// (remove-on-eject).
    public func onCardRemoved() {
        for iid in published { store.removeToken(instanceID: iid) }
        published.removeAll()
    }

    /// Full recycle on host launch: clears every token configuration
    /// currently registered under this driver class — including anything
    /// left over from a prior process, which this (freshly-constructed)
    /// instance's `published` set knows nothing about — then republishes for
    /// the currently-present card, if any.
    public func reregisterOnLaunch(currentCerts: [PublishableCert]) {
        store.clearAll()
        published.removeAll()
        onCardPresent(certs: currentCerts)
    }

    static var qesKeychainEnabled: Bool {
        ProcessInfo.processInfo.environment["LIBRESCRS_ENABLE_QES_KEYCHAIN"] == "1"
    }
}

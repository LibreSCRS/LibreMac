// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Swift RAII wrappers around the BridgeNative C ABI. The Swift caller never
// touches an `lm_*` handle directly; the destructors here guarantee that
// every successful `lm_registry_create` is paired with an
// `lm_registry_destroy`, and likewise for sessions. Per Stroustrup *The C++
// Programming Language* §13 (RAII as the canonical resource-management
// idiom), the same pattern translates one-for-one to Swift's `deinit`.
//
// LocalizedText limitation:
// This bridge currently fabricates its own `LocalizedText` (key +
// defaultText + placeholders) at the Swift seam — see the
// `error.reader.unavailable` / `error.reader.nocard` / etc. literals
// scattered through `BridgeSession.init` and the `verifyPin` / `sign`
// throw sites. The corresponding LM `Auth::LocalizedText` payload
// emitted by `CardSession::open` / `verifyPIN` / `sign` is collapsed
// into a flat `errMsg: char*` by the C ABI and re-wrapped here with a
// hand-written key. Consequence: the user-visible localised string is
// whatever LibreMac fabricates, NOT what LM resolved — Linux and macOS
// see different message text for the same underlying card error.
//
// Tracked in the project BACKLOG: extend the C ABI to surface a
// `lm_localized_text_t` triple (key + default_text + placeholder
// kv-pairs, all caller-owned, mirroring LM's
// `LibreSCRS::LocalizedText` field names) and propagate it 1:1 into
// Swift's `LocalizedText`. That would ship LM's canonical i18n keys
// end-to-end and retire the bespoke `error.*` catalogue. The current
// catalogue entries in `Localizable.xcstrings` cover the user-visible-
// locale case for the time being.

import Foundation
import os
import LibreMacShared
import CppBridge

/// CardPluginService composition root. **Constructor-injected** — pass the
/// instance down through `LibreMacApp.init()` to consumers (`BridgeSession`,
/// `CardMonitor`, `SigningCoordinator`). There is no `static let shared`
/// and no Meyers singleton: per `feedback_singleton_patterns.md` the
/// LM-facing seam follows pure constructor DI, never `instance()`/Meyers.
///
/// Lifecycle: typically constructed once at app launch and held by the
/// SwiftUI scene root. `deinit` calls `lm_registry_destroy` so the C++
/// CardPluginService and its `dlopen`'d plugin set are torn down cleanly
/// when the registry's last Swift owner drops it. Multiple registries
/// rooted at different plugin directories (e.g. system + user-installed,
/// or the future CTK appex with its own scope) are supported.
public final class BridgeRegistry: @unchecked Sendable {
    /// Serialise registry construction across concurrent first-loaders.
    private let lock = NSLock()
    /// Non-nil after a successful `loadBundledPlugins(dir:)`.
    private var handle: lm_registry_t?

    public init() {}

    deinit {
        if let h = handle {
            lm_registry_destroy(h)
        }
    }

    /// Construct the C++ registry from the bundle's PlugIns/middleware-plugins
    /// directory. Idempotent: returns the previously-loaded plugin count if
    /// already loaded.
    @discardableResult
    public func loadBundledPlugins() -> Int {
        guard let pluginsUrl = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("middleware-plugins")
        else {
            Logger.bridge.error("No PlugIns/middleware-plugins directory in bundle")
            return 0
        }
        return loadPlugins(fromDirectory: pluginsUrl.path)
    }

    /// Construct the C++ registry from an arbitrary plugins directory.
    /// Useful for tests and for hosting the bridge outside an .app bundle.
    @discardableResult
    public func loadPlugins(fromDirectory dir: String) -> Int {
        lock.lock()
        defer { lock.unlock() }

        if let existing = handle {
            return Int(max(0, lm_registry_plugin_count(existing)))
        }

        guard let r = dir.withCString({ lm_registry_create($0) }) else {
            Logger.bridge.error("lm_registry_create returned NULL for \(dir, privacy: .public)")
            return 0
        }
        handle = r
        let count = lm_registry_plugin_count(r)
        Logger.bridge.info(
            "Loaded \(count, privacy: .public) plugins from \(dir, privacy: .public)")
        return count > 0 ? Int(count) : 0
    }

    /// Internal accessor for `BridgeSession`. Returns nil if `loadBundledPlugins()`
    /// has not been called yet — callers must surface this as a hard error
    /// because no session can match a card without a registry.
    fileprivate var rawHandle: lm_registry_t? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }
}

/// RAII wrapper around `lm_session_t`. The C++ `CardSession` closes on `deinit`.
/// `BridgeSession` is a class (not a struct) because the underlying handle has
/// reference-semantics ownership — copying the Swift value must not duplicate
/// the C++ session.
///
/// **Threading model.** `BridgeSession` is **not `Sendable`**: the underlying
/// LM `CardSession` serialises APDU traffic over a single PC/SC channel and
/// the bridge does not internally synchronise concurrent calls on the same
/// handle. Strict-concurrency callers (the project sets
/// `SWIFT_STRICT_CONCURRENCY = complete`) are therefore expected to keep
/// every `BridgeSession` confined to a single isolation domain — in
/// LibreMac's case `@MainActor`, since `CardMonitor` (the sole owner) is
/// MainActor-isolated and `SigningCoordinator` (the sole consumer) borrows
/// the session via `cardMonitor.activeSession` on MainActor.
///
/// Concretely:
/// - Do **not** add `@unchecked Sendable` without first introducing an
///   internal serialisation barrier (`NSLock` around every public method)
///   AND auditing the LM-side handle for re-entrancy on PIN / sign / read.
/// - `deinit` runs on whichever thread releases the final reference; ARC
///   guarantees it runs exactly once, so `lm_session_close(handle)` is
///   safe even though the deinit is non-isolated. Same-handle double-free
///   is prevented by Swift's reference-counting invariant.
/// - If a future caller needs cross-actor access, wrap the session in an
///   `actor BridgeSessionActor` rather than relaxing the Sendable stance
///   here.
public final class BridgeSession {
    private let handle: lm_session_t

    public init(registry: BridgeRegistry, reader: String) throws(LibreMacError) {
        guard let registryHandle = registry.rawHandle else {
            throw .bridgeUnavailable(diagnostic: "registry not loaded — call loadBundledPlugins() on the injected BridgeRegistry first")
        }

        var status: lm_open_status_t = LM_OPEN_PROTOCOL_ERROR
        var errMsg: UnsafeMutablePointer<CChar>?
        let opened: lm_session_t? = reader.withCString { cReader in
            lm_session_open(registryHandle, cReader, &status, &errMsg)
        }

        guard let h = opened else {
            let message = errMsg.flatMap { String(cString: $0) } ?? "unknown"
            if let p = errMsg { lm_string_free(p) }
            switch status {
            case LM_OPEN_READER_UNAVAILABLE:
                throw .readerUnavailable(.init(key: "error.reader.unavailable",
                                               defaultText: message))
            case LM_OPEN_NO_CARD:
                throw .noCardPresent(.init(key: "error.reader.nocard",
                                           defaultText: message))
            case LM_OPEN_NO_MATCHING_PLUGIN:
                throw .unsupportedCard(.init(key: "error.card.unsupported",
                                             defaultText: message))
            default:
                throw .communicationError(.init(key: "error.reader.protocol",
                                                defaultText: message),
                                          diagnostic: nil)
            }
        }
        if let p = errMsg { lm_string_free(p) }
        self.handle = h
    }

    deinit {
        lm_session_close(handle)
    }

    /// Read all DER-encoded certificates the card exposes.
    public func readCertificates() throws(LibreMacError) -> [Data] {
        var arr: UnsafeMutablePointer<lm_buffer_t>?
        var count: Int = 0
        var errMsg: UnsafeMutablePointer<CChar>?
        let status = lm_session_read_certificates(handle, &arr, &count, &errMsg)
        defer {
            if let a = arr { lm_buffer_array_free(a, count) }
            if let p = errMsg { lm_string_free(p) }
        }
        guard status == LM_READ_OK else {
            let message = errMsg.flatMap { String(cString: $0) } ?? "unknown"
            throw .communicationError(.init(key: "error.read.certs",
                                            defaultText: message),
                                      diagnostic: nil)
        }
        guard let arr = arr else { return [] }
        var out: [Data] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let buf = arr[i]
            if let dataPtr = buf.data {
                out.append(Data(bytes: dataPtr, count: buf.length))
            } else {
                out.append(Data())
            }
        }
        return out
    }

    /// Verify a PIN against the card. Returns the retries-left count if the
    /// card reports it (negative -> unknown).
    public func verifyPin(_ pin: SecureString) throws(LibreMacError) -> Int {
        var retriesLeft: Int32 = -1
        var errMsg: UnsafeMutablePointer<CChar>?
        let status: lm_pin_status_t = pin.withCString { ptr, len in
            lm_session_verify_pin(handle, ptr, len, &retriesLeft, &errMsg)
        }
        defer { if let p = errMsg { lm_string_free(p) } }
        switch status {
        case LM_PIN_OK:
            return Int(retriesLeft)
        case LM_PIN_INCORRECT:
            throw .pinIncorrect(retriesLeft: retriesLeft >= 0 ? Int(retriesLeft) : nil)
        case LM_PIN_BLOCKED:
            throw .pinBlocked
        case LM_PIN_UNSUPPORTED:
            throw .communicationError(.init(key: "error.pin.unsupported",
                                            defaultText: "PIN verification not supported"),
                                      diagnostic: nil)
        default:
            let message = errMsg.flatMap { String(cString: $0) } ?? "device error"
            throw .communicationError(.init(key: "error.pin.device",
                                            defaultText: message),
                                      diagnostic: nil)
        }
    }

    /// Sign `data` using the key at `keyReference` with the given mechanism.
    public func sign(keyReference: UInt16,
                     mechanism: lm_sign_mechanism_t,
                     data: Data) throws(LibreMacError) -> Data {
        var sig = lm_buffer_t(data: nil, length: 0)
        var errMsg: UnsafeMutablePointer<CChar>?
        let status: lm_sign_status_t = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress
            return lm_session_sign(handle, keyReference, mechanism,
                                   bytes, raw.count, &sig, &errMsg)
        }
        defer {
            if let p = errMsg { lm_string_free(p) }
            if let p = sig.data { lm_buffer_free(p) }
        }
        guard status == LM_SIGN_OK, let p = sig.data else {
            let message = errMsg.flatMap { String(cString: $0) } ?? "sign failed"
            switch status {
            case LM_SIGN_PIN_REQUIRED:
                throw .authenticationFailed(.init(key: "error.sign.pin_required",
                                                  defaultText: "PIN required"),
                                            retriesLeft: nil)
            case LM_SIGN_CANCELLED:
                throw .userCancelled
            default:
                throw .signingEngineError(.init(key: "error.sign.engine",
                                                defaultText: message),
                                          diagnostic: nil)
            }
        }
        return Data(bytes: p, count: sig.length)
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// State for the settings window. The agent is the authority on every value
// here: this model reads a snapshot, writes one key at a time, and never
// writes a set back wholesale — so an older client cannot erase a key a
// newer agent owns.

import Foundation
import LibreMacAgentClient
import Observation

/// The slice of the agent client the settings window needs. A protocol seam
/// so the model is testable without a socket; `AgentClient` is an actor whose
/// transport cannot be stood up in a host unit test.
protocol ConfigTransport: Sendable {
    func getConfig() async throws -> [String: CBORValue]
    func setConfig(_ key: SettableConfigKey, value: CBORValue) async throws
    func resetConfig(_ key: SettableConfigKey) async throws
}

extension AgentClient: ConfigTransport {}

// Mutated from async work and read while rendering: main-actor isolated, or
// strict concurrency rejects it.
@MainActor
@Observable
final class PreferencesModel {
    enum Availability: Equatable { case loading, ready, unavailable }

    private let client: ConfigTransport

    var availability: Availability = .loading
    var defaultLevel = ""
    var defaultReason = ""
    var defaultLocation = ""
    var tsaUrls: [String] = []
    var pluginDir = ""
    var tslCacheDir = ""
    var aiaCacheDir = ""

    /// Rows the user has open. A refresh skips these, so a change made
    /// elsewhere never rewrites text somebody is in the middle of typing.
    /// Driven by `beginEditing` / `endEditing`; a view that only sets focus
    /// without calling them leaves this empty and the protection inert.
    private(set) var editing: Set<SettableConfigKey> = []
    var rowError: [SettableConfigKey: String] = [:]

    /// What each open row held before the user started changing it. This —
    /// not the row's current contents — is what a refused write puts back:
    /// by the time a write is refused the row already shows the new value,
    /// so reading it then would "restore" exactly what the agent rejected.
    private var valueBeforeEditing: [SettableConfigKey: String] = [:]

    init(client: ConfigTransport) { self.client = client }

    // MARK: - Editing lifecycle

    func beginEditing(_ key: SettableConfigKey) {
        editing.insert(key)
        valueBeforeEditing[key] = snapshotOfRow(key)
    }

    /// Commits what the user typed, then releases the row.
    func endEditing(_ key: SettableConfigKey) async {
        await commitIfChanged(key)
        editing.remove(key)
        valueBeforeEditing[key] = nil
    }

    /// Writes a text row only if it actually differs from what it held when
    /// editing began. The agent broadcasts every accepted write, so a no-op
    /// write would announce a configuration change to every other client
    /// each time a field merely lost focus.
    func commitIfChanged(_ key: SettableConfigKey) async {
        let current = snapshotOfRow(key)
        guard let before = valueBeforeEditing[key], before != current else { return }
        await save(key, .text(current))
        valueBeforeEditing[key] = snapshotOfRow(key)
    }

    func load() async {
        // This model outlives the window, so a window that closed while a
        // field had focus can leave its row marked as being edited — and a
        // marked row is skipped by every later refresh. A window that is
        // opening is editing nothing.
        editing.removeAll()
        valueBeforeEditing.removeAll()
        do {
            assign(try await client.getConfig(), skippingEdited: false)
            availability = .ready
        } catch {
            // Blank, not stale. A settings window showing a previous read as
            // if it were live is worse than one admitting it cannot read.
            clearEveryRow()
            availability = .unavailable
        }
    }

    /// Shows the new value immediately and puts the old one back if the agent
    /// refuses it. The row is set here rather than by the caller: a view that
    /// assigned it first would leave nothing to restore, since the "previous"
    /// value read at that point is already the new one.
    func save(_ key: SettableConfigKey, _ value: CBORValue) async {
        let previous = valueBeforeEditing[key] ?? snapshotOfRow(key)
        if case .text(let text) = value { restoreRow(key, to: text) }
        do {
            try await client.setConfig(key, value: value)
            rowError[key] = nil
        } catch {
            restoreRow(key, to: previous)
            rowError[key] = message(for: error)
        }
    }

    /// Re-reads only the key that was reset, for the same reason `apply`
    /// does: a full re-assign would move rows nobody touched.
    func reset(_ key: SettableConfigKey) async {
        do {
            try await client.resetConfig(key)
            rowError[key] = nil
            valueBeforeEditing[key] = nil
            let entries = try await client.getConfig()
            // Only this row. An agent that no longer publishes the key has
            // no default to show, which is an empty row, not a stale one.
            if case .text(let restored)? = entries[key.rawValue] {
                restoreRow(key, to: restored)
            } else {
                restoreRow(key, to: "")
            }
        } catch {
            rowError[key] = message(for: error)
        }
    }

    /// Re-read after the agent says a key changed, and assign **only that
    /// key**. A blanket re-assign would silently touch rows the signal never
    /// mentioned, which is how an unrelated row moves under the user's cursor.
    func apply(changedKey: String) async {
        guard let entries = try? await client.getConfig() else { return }
        assign(entries.filter { $0.key == changedKey }, skippingEdited: true)
    }

    // MARK: - Assignment

    /// A name the snapshot does not carry leaves its row alone. Both callers
    /// pass a partial snapshot at least some of the time — the change signal
    /// filters it to a single key — so "absent" here means "not mentioned",
    /// never "cleared".
    private func assign(_ entries: [String: CBORValue], skippingEdited: Bool) {
        func text(_ name: String) -> String? {
            if case .text(let value)? = entries[name] { return value }
            return nil
        }
        func put(_ key: SettableConfigKey?, _ value: String?, into field: inout String) {
            guard let value else { return }
            if let key, skippingEdited, editing.contains(key) { return }
            field = value
        }
        put(.defaultLevel, text("DefaultLevel"), into: &defaultLevel)
        put(.defaultReason, text("DefaultReason"), into: &defaultReason)
        put(.defaultLocation, text("DefaultLocation"), into: &defaultLocation)
        put(nil, text("PluginDir"), into: &pluginDir)
        put(nil, text("TslCacheDir"), into: &tslCacheDir)
        put(nil, text("AiaCacheDir"), into: &aiaCacheDir)
        if case .array(let items)? = entries["TsaUrls"] {
            tsaUrls = items.compactMap {
                if case .text(let value) = $0 { return value } else { return nil }
            }
        }
        // Entries this build does not know are simply not shown. Nothing is
        // written back wholesale — a write names one key — so an older client
        // cannot erase a newer agent's key.
    }

    private func clearEveryRow() {
        defaultLevel = ""
        defaultReason = ""
        defaultLocation = ""
        tsaUrls = []
        pluginDir = ""
        tslCacheDir = ""
        aiaCacheDir = ""
    }

    /// Exhaustive on purpose: a new settable key must be given a row here
    /// rather than silently losing its previous value on a refused write.
    private func snapshotOfRow(_ key: SettableConfigKey) -> String {
        switch key {
        case .defaultLevel: return defaultLevel
        case .defaultReason: return defaultReason
        case .defaultLocation: return defaultLocation
        case .tsaUrls, .tslSources: return ""
        }
    }

    private func restoreRow(_ key: SettableConfigKey, to value: String) {
        switch key {
        case .defaultLevel: defaultLevel = value
        case .defaultReason: defaultReason = value
        case .defaultLocation: defaultLocation = value
        case .tsaUrls, .tslSources: break
        }
    }

    // MARK: - Refusal copy

    private func message(for error: Error) -> String {
        guard case .serverError(let info)? = error as? AgentClientError,
            case .name(let name) = info.code
        else { return AppLocalization.shared.loc(Self.genericKey, Self.genericFallback) }
        let (key, fallback) = Self.copy(for: name)
        return AppLocalization.shared.loc(key, fallback)
    }

    private static let genericKey = "libremac_settings_err_save_failed"
    private static let genericFallback = "The change was not saved."

    /// The four refusals this window can provoke get their own sentence; one
    /// message for all of them would leave the user unable to tell a value
    /// the agent rejected from a setting it will not let anyone change.
    /// Exhaustive over `SyncError` (no `default`) so an appended wire name
    /// forces a copy decision here, matching the error-code table.
    private static func copy(for name: SyncError) -> (String, String) {
        switch name {
        case .notAuthorized:
            return ("libremac_settings_err_not_authorized",
                    "You are not allowed to change this setting.")
        case .invalidConfigValue:
            return ("libremac_settings_err_invalid_value",
                    "The agent rejected this value.")
        case .readOnlyConfig:
            return ("libremac_settings_err_read_only",
                    "This setting is read-only and cannot be changed here.")
        case .unknownConfigKey:
            return ("libremac_settings_err_unknown_key",
                    "This agent does not have this setting.")
        case .unknownCard, .keyNotFound, .userNotLoggedIn, .unsupportedProtocol,
             .authFailed, .communicationError, .notSupported, .unsupportedOnThisCard,
             .unsupportedSignatureParameter, .inputTooLarge, .rateLimited,
             .unknownCredential, .invalidRequest, .noResult:
            return (genericKey, genericFallback)
        }
    }
}

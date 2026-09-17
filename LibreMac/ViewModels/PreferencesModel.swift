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
    var tslSources: [TslSource] = []
    var cscaSources: [CscaSource] = []
    /// The authority the agent actually used last. Read-only agent state, so
    /// it is shown rather than offered for editing.
    var lastTsaUrl = ""
    /// What country-signing anchors the agent holds. Read-only agent state.
    /// Three-valued on purpose: "nothing imported" is not a zeroed report, and
    /// a value that failed to decode is not "nothing imported" either — the
    /// pane must not tell a person no anchors are installed because a frame
    /// was unreadable.
    var cscaAnchors: CscaAnchorReport = .nothingImported
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
    private var valueBeforeEditing: [SettableConfigKey: RowValue] = [:]

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
        // Text rows only: the list rows are edited by add and remove, each of
        // which is its own deliberate write rather than something typed and
        // later committed.
        let current = snapshotOfRow(key)
        guard let before = valueBeforeEditing[key], before != current,
            case .text(let typed) = current
        else { return }
        await save(key, .text(typed))
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
        if let optimistic = Self.rowValue(of: value, for: key) { restoreRow(key, to: optimistic) }
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
            if let restored = entries[key.rawValue].flatMap({ Self.rowValue(of: $0, for: key) }) {
                restoreRow(key, to: restored)
            } else {
                // The agent no longer publishes the key, so its default is
                // nothing: an empty row, never a stale one.
                restoreRow(key, to: Self.emptyRow(for: key))
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
        // The agent has just told us this key's current value, which settles
        // whatever the row was complaining about. Leaving the complaint up
        // next to the value it denies is how a write that the client gave up
        // waiting for — but the agent went on to apply — ends up displayed as
        // a failure beside its own result.
        if let key = SettableConfigKey(rawValue: changedKey) {
            rowError[key] = nil
        }
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
        put(nil, text("LastTsaUrl"), into: &lastTsaUrl)
        if case .array(let items)? = entries["TsaUrls"], !skippingEdited || !editing.contains(.tsaUrls) {
            tsaUrls = items.compactMap {
                if case .text(let value) = $0 { return value } else { return nil }
            }
        }
        if case .array(let items)? = entries["TslSources"], !skippingEdited || !editing.contains(.tslSources) {
            // A source without a url is dropped rather than shown as a row the
            // user cannot act on; the agent is the one that persisted it, so
            // the rest of the list still stands.
            tslSources = items.compactMap(TslSource.init(cbor:))
        }
        if case .array(let items)? = entries["CscaSources"], !skippingEdited || !editing.contains(.cscaSources) {
            // Read even though no pane draws it. The row exists so that a
            // refused write can restore what was there; a row that is never
            // filled would restore emptiness over a list the agent holds, which
            // is the rollback bug this model is built to avoid rather than a
            // harmless gap.
            cscaSources = items.compactMap(CscaSource.init(cbor:))
        }
        // Read-only agent state. Present-but-empty is the wire's "nothing has
        // been imported", so it clears the row; absent leaves it alone, like
        // every other name this snapshot does not carry.
        if let state = entries["CscaAnchorState"] {
            cscaAnchors = CscaAnchorReport(cbor: state)
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
        tslSources = []
        cscaSources = []
        lastTsaUrl = ""
        cscaAnchors = .nothingImported
        pluginDir = ""
        tslCacheDir = ""
        aiaCacheDir = ""
    }

    /// What a row holds, whatever its shape. One rollback path covers them
    /// all: a list row that could only snapshot itself as a string would
    /// "restore" an empty list over everything the user had entered, which is
    /// the scalar rollback bug again in the place that loses the most.
    enum RowValue: Equatable {
        case text(String)
        case urls([String])
        case sources([TslSource])
        case cscaSources([CscaSource])
    }

    /// Exhaustive on purpose: a new settable key must be given a row here
    /// rather than silently losing its previous value on a refused write.
    private func snapshotOfRow(_ key: SettableConfigKey) -> RowValue {
        switch key {
        case .defaultLevel: return .text(defaultLevel)
        case .defaultReason: return .text(defaultReason)
        case .defaultLocation: return .text(defaultLocation)
        case .tsaUrls: return .urls(tsaUrls)
        case .tslSources: return .sources(tslSources)
        case .cscaSources: return .cscaSources(cscaSources)
        }
    }

    private func restoreRow(_ key: SettableConfigKey, to value: RowValue) {
        switch (key, value) {
        case (.defaultLevel, .text(let v)): defaultLevel = v
        case (.defaultReason, .text(let v)): defaultReason = v
        case (.defaultLocation, .text(let v)): defaultLocation = v
        case (.tsaUrls, .urls(let v)): tsaUrls = v
        case (.tslSources, .sources(let v)): tslSources = v
        case (.cscaSources, .cscaSources(let v)): cscaSources = v
        default:
            // A shape that does not belong to this key. Restoring anything
            // here would be inventing a value; leaving the row alone is the
            // only honest option.
            break
        }
    }

    /// What "no value" looks like for a row, so a reset can clear it without
    /// the caller knowing the row's shape.
    private static func emptyRow(for key: SettableConfigKey) -> RowValue {
        switch key {
        case .defaultLevel, .defaultReason, .defaultLocation: return .text("")
        case .tsaUrls: return .urls([])
        case .tslSources: return .sources([])
        case .cscaSources: return .cscaSources([])
        }
    }

    /// The row a value carries, for the optimistic write. Returns nil for a
    /// shape this build has no row for, so `save` shows nothing rather than
    /// guessing.
    ///
    /// Takes the KEY, and no longer guesses from the value alone. It used to
    /// sniff the first array element: text meant a URL list, anything else meant
    /// trusted-list sources. That worked while exactly one key carried maps.
    /// With country-signing sources there are two map-shaped rows whose wire
    /// forms differ only in their keys, so a guess would silently hand one row's
    /// value to the other -- and both call sites already know which key they are
    /// writing, so the guess was never necessary.
    private static func rowValue(of value: CBORValue, for key: SettableConfigKey) -> RowValue? {
        switch key {
        case .defaultLevel, .defaultReason, .defaultLocation:
            if case .text(let s) = value { return .text(s) }
            return nil
        case .tsaUrls:
            guard case .array(let items) = value else { return nil }
            return .urls(items.compactMap { if case .text(let s) = $0 { return s } else { return nil } })
        case .tslSources:
            guard case .array(let items) = value else { return nil }
            return .sources(items.compactMap(TslSource.init(cbor:)))
        case .cscaSources:
            guard case .array(let items) = value else { return nil }
            return .cscaSources(items.compactMap(CscaSource.init(cbor:)))
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

    /// The four refusals this window can provoke get their own sentence, and
    /// so does a dismissed prompt, which is not a refusal at all; one message
    /// for all of them would leave the user unable to tell a value the agent
    /// rejected from a setting it will not let anyone change, or from having
    /// closed the prompt oneself.
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
        case .cancelled:
            // A dismissed prompt is not a refusal: the agent did not decline
            // the value, the person simply did not answer. The generic
            // sentence stops at "the change was not saved", which reads as a
            // failure to investigate rather than as one's own act.
            return ("libremac_settings_err_cancelled",
                    "You closed the prompt, so the change was not saved.")
        // masterListReplayed sits here rather than getting its own sentence,
        // and that is a decision about THIS window, not about the refusal. It
        // answers a master-list import -- "you already have this list, or this
        // one is older" -- and no control here starts one. A settings pane that
        // explained a refusal it cannot provoke would be copy nobody can reach,
        // and the day this host does gain an import path it will want the
        // sentence next to that control, not next to the level and location
        // fields. Moving it out of this list is then the reminder.
        case .unknownCard, .keyNotFound, .userNotLoggedIn, .unsupportedProtocol,
             .authFailed, .communicationError, .notSupported, .unsupportedOnThisCard,
             .unsupportedSignatureParameter, .inputTooLarge, .rateLimited,
             .unknownCredential, .invalidRequest, .noResult, .masterListReplayed:
            return (genericKey, genericFallback)
        }
    }
}

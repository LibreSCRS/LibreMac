// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The settings window's state, including the states it cannot read. Two
// claims carry the weight: an agent it cannot reach shows nothing rather
// than a stale value rendered as live, and a refused write leaves the row
// exactly as the agent still has it.

import Foundation
import LibreMacAgentClient
import Testing

@testable import LibreMac

/// Mutable because two tests change what the agent would answer partway
/// through, which is the whole point of the refresh assertions.
final class FakeConfigClient: ConfigTransport, @unchecked Sendable {
    var entries: [String: CBORValue]
    var failure: AgentClientError?
    var failNextWrite: SyncError?
    private(set) var resetKeys: [SettableConfigKey] = []
    private(set) var writtenKeys: [SettableConfigKey] = []

    init(entries: [String: CBORValue] = [:], failure: AgentClientError? = nil) {
        self.entries = entries
        self.failure = failure
    }

    func getConfig() async throws -> [String: CBORValue] {
        if let failure { throw failure }
        return entries
    }

    func setConfig(_ key: SettableConfigKey, value: CBORValue) async throws {
        writtenKeys.append(key)
        if let name = failNextWrite {
            failNextWrite = nil
            throw AgentClientError.serverError(ErrInfo(code: .name(name)))
        }
        entries[key.rawValue] = value
    }

    func resetConfig(_ key: SettableConfigKey) async throws {
        resetKeys.append(key)
        if let name = failNextWrite {
            failNextWrite = nil
            throw AgentClientError.serverError(ErrInfo(code: .name(name)))
        }
        entries.removeValue(forKey: key.rawValue)
    }
}

@Suite("Preferences model")
@MainActor
struct PreferencesModelTests {

    @Test("a snapshot populates the rows it knows and ignores the ones it does not")
    func snapshotPopulatesKnownRows() async {
        let model = PreferencesModel(
            client: FakeConfigClient(entries: [
                "DefaultLevel": .text("b-t"),
                "DefaultReason": .text("Approval"),
                "PluginDir": .text("/opt/plugins"),
                "SomethingFromTheFuture": .text("ignored"),
            ]))

        await model.load()

        #expect(model.availability == .ready)
        #expect(model.defaultLevel == "b-t")
        #expect(model.pluginDir == "/opt/plugins")
    }

    @Test("an unreachable agent reports unavailable and shows no value at all")
    func unreachableAgentShowsNothing() async {
        let model = PreferencesModel(client: FakeConfigClient(failure: .notConnected))

        await model.load()

        #expect(model.availability == .unavailable)
        #expect(model.defaultReason.isEmpty, "a stale value rendered as live is worse than none")
    }

    /// A read that succeeded once must not leave its values on screen when a
    /// later read fails: the window would then be showing the agent's old
    /// answer as if it were current.
    @Test("a later unreachable read clears what an earlier one populated")
    func laterFailureClearsEarlierValues() async {
        let fake = FakeConfigClient(entries: ["DefaultReason": .text("Approval")])
        let model = PreferencesModel(client: fake)
        await model.load()
        #expect(model.defaultReason == "Approval")

        fake.failure = .connectionLost
        await model.load()

        #expect(model.availability == .unavailable)
        #expect(model.defaultReason.isEmpty)
    }

    @Test("a refused write leaves the row's error set and the value unchanged")
    func refusedWriteKeepsPreviousValue() async {
        let fake = FakeConfigClient(entries: ["DefaultReason": .text("Approval")])
        fake.failNextWrite = .notAuthorized
        let model = PreferencesModel(client: fake)
        await model.load()

        await model.save(.defaultReason, .text("Rejected"))

        #expect(model.defaultReason == "Approval")
        #expect(model.rowError[.defaultReason] != nil)
    }

    /// Each refusal the agent can give this window gets its own sentence, and
    /// so does a dismissed prompt — one message for all five would tell the
    /// user nothing about which of them happened, and would in particular
    /// report their own cancel as something that went wrong.
    @Test("the four configuration refusals and a cancel render five distinct sentences")
    func eachRefusalHasItsOwnSentence() async {
        var messages: Set<String> = []
        for name in [SyncError.notAuthorized, .invalidConfigValue,
                     .readOnlyConfig, .unknownConfigKey, .cancelled] {
            let fake = FakeConfigClient(entries: ["DefaultReason": .text("Approval")])
            fake.failNextWrite = name
            let model = PreferencesModel(client: fake)
            await model.load()

            await model.save(.defaultReason, .text("Rejected"))

            let message = model.rowError[.defaultReason]
            #expect(message?.isEmpty == false, "\(name) produced no message")
            if let message { messages.insert(message) }
        }
        #expect(messages.count == 5, "refusals share copy: \(messages.sorted())")
    }

    @Test("a successful write clears the row's earlier error")
    func successfulWriteClearsTheError() async {
        let fake = FakeConfigClient(entries: ["DefaultReason": .text("Approval")])
        fake.failNextWrite = .notAuthorized
        let model = PreferencesModel(client: fake)
        await model.load()
        await model.save(.defaultReason, .text("Rejected"))
        #expect(model.rowError[.defaultReason] != nil)

        await model.save(.defaultReason, .text("Accepted"))

        #expect(model.rowError[.defaultReason] == nil)
    }

    /// The path the window actually takes: the row is already showing the
    /// new value by the time the write is refused, because the user typed it
    /// there. Reading the row at refusal time and calling that "previous"
    /// restores exactly what the agent rejected — which is what the earlier
    /// version of this model did, and what calling `save` on an untouched
    /// model failed to catch.
    @Test("a refusal restores what the row held before the user changed it")
    func refusalRestoresThePreEditValue() async {
        let fake = FakeConfigClient(entries: ["DefaultReason": .text("Approval")])
        let model = PreferencesModel(client: fake)
        await model.load()

        model.beginEditing(.defaultReason)
        model.defaultReason = "Rejected"
        fake.failNextWrite = .notAuthorized
        await model.endEditing(.defaultReason)

        #expect(model.defaultReason == "Approval")
        #expect(model.rowError[.defaultReason] != nil)
    }

    /// Same trap on the popup path, which has no editing session at all: the
    /// binding must not assign the row before asking, or there is again
    /// nothing left to restore.
    @Test("a refused level selection puts the previous level back")
    func refusedLevelSelectionRestores() async {
        let fake = FakeConfigClient(entries: ["DefaultLevel": .text("b-b")])
        let model = PreferencesModel(client: fake)
        await model.load()
        fake.failNextWrite = .readOnlyConfig

        await model.save(.defaultLevel, .text("b-lta"))

        #expect(model.defaultLevel == "b-b")
        #expect(model.rowError[.defaultLevel] != nil)
    }

    @Test("an accepted write leaves the new value showing")
    func acceptedWriteShowsTheNewValue() async {
        let fake = FakeConfigClient(entries: ["DefaultLevel": .text("b-b")])
        let model = PreferencesModel(client: fake)
        await model.load()

        await model.save(.defaultLevel, .text("b-t"))

        #expect(model.defaultLevel == "b-t")
        #expect(model.rowError[.defaultLevel] == nil)
    }

    /// Leaving a field alone must not write. The agent broadcasts every
    /// accepted write, so a no-op commit would tell every other client the
    /// configuration changed each time a field merely lost focus.
    @Test("leaving an untouched field writes nothing")
    func untouchedFieldWritesNothing() async {
        let fake = FakeConfigClient(entries: ["DefaultReason": .text("Approval")])
        let model = PreferencesModel(client: fake)
        await model.load()

        model.beginEditing(.defaultReason)
        await model.endEditing(.defaultReason)

        #expect(fake.writtenKeys.isEmpty)
    }

    /// The model outlives the window now, so an editing mark left behind by
    /// a window that closed mid-edit would stay set for the rest of the
    /// session — and that row would quietly stop following the agent. A
    /// freshly opened window is editing nothing.
    @Test("loading releases any row a closed window left marked as edited")
    func loadReleasesStaleEditingMarks() async {
        let fake = FakeConfigClient(entries: ["DefaultReason": .text("Approval")])
        let model = PreferencesModel(client: fake)
        await model.load()
        model.beginEditing(.defaultReason)

        await model.load()

        fake.entries["DefaultReason"] = .text("changed elsewhere")
        await model.apply(changedKey: "DefaultReason")

        #expect(model.defaultReason == "changed elsewhere")
    }

    /// A write the client stopped waiting for, that the agent then applied,
    /// arrives back as a change signal. The row must not show the new value
    /// and a failure message about it at the same time.
    @Test("a change signal for a row clears that row's stale error")
    func changeSignalClearsTheRowError() async {
        let fake = FakeConfigClient(entries: ["TsaUrls": .array([])])
        let model = PreferencesModel(client: fake)
        await model.load()
        fake.failNextWrite = .notAuthorized
        await model.save(.tsaUrls, .array([.text("https://tsa.example/")]))
        #expect(model.rowError[.tsaUrls] != nil)

        fake.entries["TsaUrls"] = .array([.text("https://tsa.example/")])
        await model.apply(changedKey: "TsaUrls")

        #expect(model.tsaUrls == ["https://tsa.example/"])
        #expect(model.rowError[.tsaUrls] == nil, "the value and a denial of it cannot both be true")
    }

    @Test("an external change never overwrites the row the user is editing")
    func refreshDoesNotClobberAnEdit() async {
        let fake = FakeConfigClient(entries: ["DefaultReason": .text("Approval")])
        let model = PreferencesModel(client: fake)
        await model.load()

        model.beginEditing(.defaultReason)
        model.defaultReason = "half-typed"
        fake.entries["DefaultReason"] = .text("changed elsewhere")
        await model.apply(changedKey: "DefaultReason")

        #expect(model.defaultReason == "half-typed")
    }

    @Test("an external change updates a row nobody is editing")
    func refreshUpdatesAnIdleRow() async {
        let fake = FakeConfigClient(entries: ["DefaultReason": .text("Approval")])
        let model = PreferencesModel(client: fake)
        await model.load()

        fake.entries["DefaultReason"] = .text("changed elsewhere")
        await model.apply(changedKey: "DefaultReason")

        #expect(model.defaultReason == "changed elsewhere")
    }

    /// The signal names one key. Re-reading everything and assigning it all
    /// would touch rows the agent never said had changed, which is how an
    /// unrelated row moves under the user's cursor.
    @Test("a change signal touches only the key it names")
    func refreshTouchesOnlyTheNamedKey() async {
        let fake = FakeConfigClient(entries: [
            "DefaultReason": .text("Approval"),
            "DefaultLocation": .text("Belgrade"),
        ])
        let model = PreferencesModel(client: fake)
        await model.load()

        fake.entries["DefaultReason"] = .text("changed elsewhere")
        fake.entries["DefaultLocation"] = .text("moved too")
        await model.apply(changedKey: "DefaultReason")

        #expect(model.defaultReason == "changed elsewhere")
        #expect(model.defaultLocation == "Belgrade", "an unnamed row moved")
    }

    @Test("a reset asks the agent for the key and re-reads what it now says")
    func resetRestoresTheAgentDefault() async {
        let fake = FakeConfigClient(entries: ["DefaultReason": .text("Approval")])
        let model = PreferencesModel(client: fake)
        await model.load()

        await model.reset(.defaultReason)

        #expect(fake.resetKeys == [.defaultReason])
        #expect(model.defaultReason.isEmpty, "the key is gone, so the row shows nothing")
        #expect(model.rowError[.defaultReason] == nil)
    }

    /// The scalar rollback bug again, in the row that loses the most: a list
    /// row whose snapshot could only be a string would "restore" an empty
    /// list over every entry the user had.
    @Test("a refused list write restores the whole previous list")
    func refusedListWriteRestoresTheList() async {
        let fake = FakeConfigClient(entries: [
            "TsaUrls": .array([.text("https://one.example/"), .text("https://two.example/")])
        ])
        let model = PreferencesModel(client: fake)
        await model.load()
        fake.failNextWrite = .notAuthorized

        await model.save(.tsaUrls, .array([.text("https://three.example/")]))

        #expect(model.tsaUrls == ["https://one.example/", "https://two.example/"])
        #expect(model.rowError[.tsaUrls] != nil)
    }

    @Test("a refused trusted-list write restores the whole previous list")
    func refusedSourcesWriteRestoresTheList() async {
        let existing = TslSource(url: "https://lotl.example/", isLotl: true, eager: false)
        let fake = FakeConfigClient(entries: ["TslSources": .array([existing.cbor])])
        let model = PreferencesModel(client: fake)
        await model.load()
        #expect(model.tslSources == [existing])
        fake.failNextWrite = .readOnlyConfig

        await model.save(.tslSources, .array([TslSource(url: "https://other.example/").cbor]))

        #expect(model.tslSources == [existing])
    }

    @Test("an accepted list write leaves the new list showing")
    func acceptedListWriteShowsTheNewList() async {
        let fake = FakeConfigClient(entries: ["TsaUrls": .array([.text("https://one.example/")])])
        let model = PreferencesModel(client: fake)
        await model.load()

        await model.save(.tsaUrls, .array([.text("https://one.example/"), .text("https://two.example/")]))

        #expect(model.tsaUrls == ["https://one.example/", "https://two.example/"])
        #expect(model.rowError[.tsaUrls] == nil)
    }

    /// Resetting a list key means discarding every entry, so the row has to
    /// end up empty rather than holding whatever a string-shaped reset would
    /// have put there.
    @Test("resetting a list key empties it")
    func resettingAListEmptiesIt() async {
        let fake = FakeConfigClient(entries: ["TsaUrls": .array([.text("https://one.example/")])])
        let model = PreferencesModel(client: fake)
        await model.load()

        await model.reset(.tsaUrls)

        #expect(model.tsaUrls.isEmpty)
        #expect(fake.resetKeys == [.tsaUrls])
    }

    /// The agent persisted these, so one unreadable entry must not take the
    /// rest of the list with it.
    @Test("a source the agent wrote without a url is dropped, the rest survive")
    func sourceWithoutAUrlIsDropped() async {
        let good = TslSource(url: "https://good.example/")
        let headless = CBORValue.map([(Data("eager".utf8), .bool(true))])
        let model = PreferencesModel(
            client: FakeConfigClient(entries: ["TslSources": .array([headless, good.cbor])]))

        await model.load()

        #expect(model.tslSources == [good])
    }

    @Test("a list value populates the read-only servers row")
    func listValuePopulatesTsaUrls() async {
        let model = PreferencesModel(
            client: FakeConfigClient(entries: [
                "TsaUrls": .array([.text("https://tsa.example/one"),
                                   .text("https://tsa.example/two")])
            ]))

        await model.load()

        #expect(model.tsaUrls == ["https://tsa.example/one", "https://tsa.example/two"])
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
import Foundation
@testable import LibreMacAgentClient

// The types in this package mirror a wire contract that is maintained in
// another repository. Nothing but a comment used to connect the two, and the
// drift that gap allowed has already reached users once. These tests read the
// contract's own published vocabulary list and hold the mirrors against it.
//
// Every expectation here is derived -- from the manifest, from `CaseIterable`,
// or from a switch the compiler forces to be exhaustive. Writing the expected
// values out by hand would just add one more copy to keep in step. The single
// set that is spelled out says so where it stands, and says why it has no type
// to be derived from.

private struct Manifest: Decodable {
    struct NumericEntry: Decodable {
        let value: UInt32
        let name: String
    }
    struct Vocabulary: Decodable {
        let kind: String
        let cddlOnly: Bool?
        let numeric: [NumericEntry]?
        let tokens: [String]?

        private enum CodingKeys: String, CodingKey { case kind, cddlOnly, entries }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            cddlOnly = try c.decodeIfPresent(Bool.self, forKey: .cddlOnly)
            if kind == "numeric" {
                numeric = try c.decode([NumericEntry].self, forKey: .entries)
                tokens = nil
            } else {
                tokens = try c.decode([String].self, forKey: .entries)
                numeric = nil
            }
        }
    }
    let schema: Int
    let vocabularies: [String: Vocabulary]
}

private func loadManifest() throws -> Manifest {
    let url = try #require(
        Bundle.module.url(forResource: "wire-vocabulary", withExtension: "json", subdirectory: "Contract"))
    return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
}

private func pinnedRevision() throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: "wire-vocabulary", withExtension: "provenance", subdirectory: "Contract"))
    return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test func manifestIsTheSchemaThisTestUnderstands() throws {
    let manifest = try loadManifest()
    #expect(manifest.schema == 1)
    // Surfaced on every run so the pinned revision is visible without digging
    // through a job log.
    print("wire contract pinned at \(try pinnedRevision())")
}

// The numeric mirrors are checked the same way, so the check is written once.
// Declaring the conformances here rather than on the types keeps this a
// testing concern: the production types gain nothing they do not already have.
private protocol WireNumericMirror: Equatable {
    init(wireValue: UInt32)
    var wireValue: UInt32 { get }
    var wireName: String { get }
    // An enum case with a matching associated value satisfies this.
    static func unknown(_ raw: UInt32) -> Self
}

extension ErrorCode: WireNumericMirror {}
extension OperationPhase: WireNumericMirror {}
extension OperationStatus: WireNumericMirror {}
extension PreReadAuth: WireNumericMirror {}
extension QuiesceReason: WireNumericMirror {}

private func expectNumericMirror<T: WireNumericMirror>(
    _ type: T.Type, _ rule: String, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let entries = try #require(
        try loadManifest().vocabularies[rule]?.numeric,
        "the manifest carries no numeric vocabulary '\(rule)'", sourceLocation: sourceLocation)

    for entry in entries {
        let decoded = T(wireValue: entry.value)
        #expect(decoded != T.unknown(entry.value),
                "\(rule): no case for wire value \(entry.value) (\(entry.name))",
                sourceLocation: sourceLocation)
        #expect(decoded.wireValue == entry.value, "\(rule): value \(entry.value) does not round-trip",
                sourceLocation: sourceLocation)
        #expect(decoded.wireName == entry.name,
                "\(rule): value \(entry.value) is named '\(decoded.wireName)' here but '\(entry.name)' in the contract",
                sourceLocation: sourceLocation)
    }

    // Catches a case added past the contract's last value -- the slot an
    // append mistake actually lands in.
    let past = try #require(entries.map(\.value).max(), sourceLocation: sourceLocation) + 1
    #expect(T(wireValue: past) == T.unknown(past),
            "\(rule): a case exists past the contract's last value", sourceLocation: sourceLocation)
}

// A token mirror whose members are exactly what the contract publishes. Eight
// vocabularies were checked by eight copies of these three lines, and the
// copies said nothing the type did not.
private func expectTokenMirror<T: CaseIterable & RawRepresentable>(
    _ type: T.Type, _ rule: String, sourceLocation: SourceLocation = #_sourceLocation
) throws where T.RawValue == String {
    let vocab = try #require(
        try loadManifest().vocabularies[rule],
        "the manifest carries no vocabulary '\(rule)'", sourceLocation: sourceLocation)
    let tokens = try #require(vocab.tokens, sourceLocation: sourceLocation)
    #expect(Set(T.allCases.map(\.rawValue)) == Set(tokens),
            "\(rule): the mirror does not match the contract", sourceLocation: sourceLocation)
}

// Each of the three sign-option vocabularies exists on the wire in two shapes,
// and the contract publishes BOTH. The RESOLVED rule (`sign-level`) is what a
// signature can actually be; the REQUEST rule (`requested-level`) is what a
// caller may ask for, and it is the resolved rule plus exactly one added
// literal: the deferral sentinel that asks the agent to resolve the value from
// its own configuration. The mirrors in this package are the request form, so
// each is held against the request rule as an ordinary token mirror -- which is
// what finally puts the sentinel's own spelling under this gate.
//
// The resolved rules keep a check of their own, so the asymmetry is asserted in
// BOTH directions instead of filtered away. A contract that published the
// sentinel as a resolved value -- meaning a RESULT could carry it -- would fail
// there rather than be absorbed silently, which is the whole reason these tests
// exist.

// Which resolved rule each request rule widens. The sentinel itself is not
// written here: it is whatever the contract adds, read back off the manifest.
private let requestFormBases = [
    "requested-format": "sign-format",
    "requested-level": "sign-level",
    "requested-packaging": "packaging-mode",
]

// The added literal, taken from the contract rather than copied into this file.
// All three request rules must add exactly one member to their resolved rule,
// and must add the SAME one: anything else means the shape this file reads as
// "one deferral sentinel" has changed, and every assertion built on it is void.
private func deferralSentinel(sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
    let manifest = try loadManifest()
    var added: Set<String> = []
    for (requested, resolved) in requestFormBases.sorted(by: { $0.key < $1.key }) {
        let wide = Set(try #require(
            manifest.vocabularies[requested]?.tokens,
            "the manifest carries no token vocabulary '\(requested)'", sourceLocation: sourceLocation))
        let narrow = Set(try #require(
            manifest.vocabularies[resolved]?.tokens,
            "the manifest carries no token vocabulary '\(resolved)'", sourceLocation: sourceLocation))
        let extra = wide.subtracting(narrow)
        try #require(
            extra.count == 1,
            "\(requested): adds \(extra.sorted()) to \(resolved), which is not one deferral sentinel",
            sourceLocation: sourceLocation)
        added.formUnion(extra)
    }
    try #require(
        added.count == 1,
        "the request forms disagree on the deferral sentinel: \(added.sorted())",
        sourceLocation: sourceLocation)
    return try #require(added.first, sourceLocation: sourceLocation)
}

// The sentinel this package sends and the one the contract adds are one value.
// It is spelled once per request-form enum here and once per request rule
// there; this is where the two sides meet.
@Test func theDeferralSentinelIsTheContractsOwn() throws {
    let sentinel = try deferralSentinel()
    #expect(SignatureFormat.auto.rawValue == sentinel)
    #expect(SignatureLevel.auto.rawValue == sentinel)
    #expect(Packaging.auto.rawValue == sentinel)
}

private func expectRequestFormMirror<T: CaseIterable & RawRepresentable>(
    _ type: T.Type, _ rule: String, sourceLocation: SourceLocation = #_sourceLocation
) throws where T.RawValue == String {
    let vocab = try #require(
        try loadManifest().vocabularies[rule],
        "the manifest carries no vocabulary '\(rule)'", sourceLocation: sourceLocation)
    let published = Set(try #require(vocab.tokens, sourceLocation: sourceLocation))
    let declared = Set(T.allCases.map(\.rawValue))
    let sentinel = try deferralSentinel(sourceLocation: sourceLocation)

    #expect(!published.contains(sentinel),
            "\(rule): the contract now publishes '\(sentinel)' as a resolved value, so it can reach a result -- this mirror's request-only reading of it no longer holds",
            sourceLocation: sourceLocation)
    #expect(declared.contains(sentinel),
            "\(rule): the mirror lost its deferral sentinel, so a caller can no longer ask the agent to choose",
            sourceLocation: sourceLocation)
    #expect(declared.subtracting([sentinel]) == published,
            "\(rule): the mirror's resolved members do not match the contract",
            sourceLocation: sourceLocation)
}

// The wider config rule is the settable keys plus the ones the agent owns and
// only ever reports. This package has no type for the wider set and needs none:
// the only request that names a config key, `ResetConfig`, is reached through
// `AgentClient.resetConfig`, which takes a `SettableConfigKey` -- so no typed
// path in this package sends one of these five (the raw `send(_:)` of the token
// client accepts any request, which is what the wire intends). They are
// therefore spelled out, in the one
// place they are spelled at all, rather than mirrored by an enum no caller
// would have a use for. A sixth key appended on the agent side lands here as a
// failure to read and decide about, which is the whole point of publishing the
// wider rule.
private let readOnlyConfigKeys: Set<String> = [
    "LastTsaUrl", "CscaAnchorState", "TslCacheDir", "AiaCacheDir", "PluginDir",
]

private func expectConfigKeyMirror(sourceLocation: SourceLocation = #_sourceLocation) throws {
    let vocab = try #require(
        try loadManifest().vocabularies["config-key"],
        "the manifest carries no vocabulary 'config-key'", sourceLocation: sourceLocation)
    let published = Set(try #require(vocab.tokens, sourceLocation: sourceLocation))
    let settable = Set(SettableConfigKey.allCases.map(\.rawValue))

    // The settable half stays derived; only the read-only half is written out.
    #expect(published == settable.union(readOnlyConfigKeys),
            "config-key: the contract's wider key set is not the settable mirror plus the read-only keys named here",
            sourceLocation: sourceLocation)
    // A key that moved from read-only to settable is a different question --
    // one this package answers with a new `SettableConfigKey` case, not here.
    #expect(settable.isDisjoint(with: readOnlyConfigKeys), sourceLocation: sourceLocation)
}

private struct BitPair: Hashable {
    let bit: UInt32
    let name: String
}

private func expectCapabilityBitsMirror(sourceLocation: SourceLocation = #_sourceLocation) throws {
    // The published values are bit INDICES (Pki: 0, IdentityData: 1, ...),
    // matching `Capabilities.Bit`'s raw values -- not the 1/2/4/8 masks the
    // OptionSet members carry.
    let entries = try #require(
        try loadManifest().vocabularies["capability-bit"]?.numeric, sourceLocation: sourceLocation)

    let declared = Set(Capabilities.Bit.allCases.map { BitPair(bit: $0.rawValue, name: $0.wireName) })
    let published = Set(entries.map { BitPair(bit: $0.value, name: $0.name) })
    #expect(declared == published, sourceLocation: sourceLocation)
}

// One entry per vocabulary the contract publishes. This table is the single
// source of truth for both halves of the question: it says what each mirror is
// checked against, and -- through `everyPublishedVocabularyIsChecked` below --
// what it means for the set of mirrors to be complete. A rule cannot be listed
// here without its check actually running, and a rule the contract publishes
// with no entry here fails.
//
// That completeness test is the one this file was missing, and the gap was not
// hypothetical. The mirrors were written one per vocabulary that existed when
// this gate was built, and nothing said the set had to STAY complete. When the
// contract later published `sign-format`, `sign-level` and `packaging-mode`,
// no test could fail: there was simply nothing checking them. Only the
// freshness workflow noticed, and by design it reports rather than blocks.
private let vocabularyChecks: [String: @Sendable () throws -> Void] = [
    "error-code": { try expectNumericMirror(ErrorCode.self, "error-code") },
    "op-phase": { try expectNumericMirror(OperationPhase.self, "op-phase") },
    "op-status": { try expectNumericMirror(OperationStatus.self, "op-status") },
    "pre-read-auth": { try expectNumericMirror(PreReadAuth.self, "pre-read-auth") },
    "quiesce-reason": { try expectNumericMirror(QuiesceReason.self, "quiesce-reason") },
    "capability-bit": { try expectCapabilityBitsMirror() },
    "cred-verb": { try expectTokenMirror(CredentialVerb.self, "cred-verb") },
    "cred-outcome": { try expectTokenMirror(CredentialOutcome.self, "cred-outcome") },
    "cred-kind": { try expectTokenMirror(CredentialKind.self, "cred-kind") },
    "cred-state": { try expectTokenMirror(CredentialState.self, "cred-state") },
    "cred-recovery": { try expectTokenMirror(CredentialRecovery.self, "cred-recovery") },
    "unblock-style": { try expectTokenMirror(CredentialUnblockStyle.self, "unblock-style") },
    "sync-error": { try expectTokenMirror(SyncError.self, "sync-error") },
    "settable-config-key": { try expectTokenMirror(SettableConfigKey.self, "settable-config-key") },
    "sign-format": { try expectRequestFormMirror(SignatureFormat.self, "sign-format") },
    "sign-level": { try expectRequestFormMirror(SignatureLevel.self, "sign-level") },
    "packaging-mode": { try expectRequestFormMirror(Packaging.self, "packaging-mode") },
    "requested-format": { try expectTokenMirror(SignatureFormat.self, "requested-format") },
    "requested-level": { try expectTokenMirror(SignatureLevel.self, "requested-level") },
    "requested-packaging": { try expectTokenMirror(Packaging.self, "requested-packaging") },
    "config-key": { try expectConfigKeyMirror() },
]

@Test(arguments: vocabularyChecks.keys.sorted())
func mirrorMatchesTheContract(_ rule: String) throws {
    let check = try #require(vocabularyChecks[rule], "no check registered for '\(rule)'")
    try check()
}

// Note this deliberately does NOT exempt the `cddlOnly` vocabularies. That flag
// marks a rule with no upstream C++ *enum* to compare against (`cred-verb` and
// the two config-key rules are string constants agent-side), which is a
// statement about the agent, not about this client -- all three are mirrored
// here like any other. Reading it as "no mirror expected" would punch a hole
// in exactly the check this test exists to be.
@Test func everyPublishedVocabularyIsChecked() throws {
    let published = Set(try loadManifest().vocabularies.keys)
    let checked = Set(vocabularyChecks.keys)

    #expect(published.subtracting(checked).isEmpty,
            "the contract publishes vocabularies nothing here checks: \(published.subtracting(checked).sorted())")
    #expect(checked.subtracting(published).isEmpty,
            "checks here name vocabularies the contract no longer publishes: \(checked.subtracting(published).sorted())")
}

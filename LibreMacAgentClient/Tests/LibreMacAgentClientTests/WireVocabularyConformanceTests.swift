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
// values out by hand would just add one more copy to keep in step.

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

// The three sign-option vocabularies need their own shape. What the contract
// publishes is the RESOLVED form of each -- what a signature can actually be --
// while the mirrors here are the REQUEST form, so each mirror carries exactly
// one member the contract does not publish: `auto`, the deferral sentinel that
// asks the agent to resolve the value from its own configuration. The contract
// draws the same line (`requested-level = sign-level / "auto"`, and `sign-meta`
// reports only resolved forms), and says why the requested forms are not
// published: a rule that names another rule is not a closed list of literals,
// and spelling the members out a second time would reintroduce the hand-copied
// vocabulary this manifest exists to remove.
//
// So the asymmetry is asserted in BOTH directions instead of filtered away. A
// contract that later published `auto` as a resolved value -- meaning a result
// could carry it -- would fail here rather than be absorbed silently, which is
// the whole reason these tests exist.

private let deferralSentinel = "auto"

private func expectRequestFormMirror<T: CaseIterable & RawRepresentable>(
    _ type: T.Type, _ rule: String, sourceLocation: SourceLocation = #_sourceLocation
) throws where T.RawValue == String {
    let vocab = try #require(
        try loadManifest().vocabularies[rule],
        "the manifest carries no vocabulary '\(rule)'", sourceLocation: sourceLocation)
    let published = Set(try #require(vocab.tokens, sourceLocation: sourceLocation))
    let declared = Set(T.allCases.map(\.rawValue))

    #expect(!published.contains(deferralSentinel),
            "\(rule): the contract now publishes '\(deferralSentinel)' as a resolved value, so it can reach a result -- this mirror's request-only reading of it no longer holds",
            sourceLocation: sourceLocation)
    #expect(declared.contains(deferralSentinel),
            "\(rule): the mirror lost its deferral sentinel, so a caller can no longer ask the agent to choose",
            sourceLocation: sourceLocation)
    #expect(declared.subtracting([deferralSentinel]) == published,
            "\(rule): the mirror's resolved members do not match the contract",
            sourceLocation: sourceLocation)
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
]

@Test(arguments: vocabularyChecks.keys.sorted())
func mirrorMatchesTheContract(_ rule: String) throws {
    let check = try #require(vocabularyChecks[rule], "no check registered for '\(rule)'")
    try check()
}

// Note this deliberately does NOT exempt the `cddlOnly` vocabularies. That flag
// marks a rule with no upstream C++ *enum* to compare against (`cred-verb` and
// `settable-config-key` are string constants agent-side), which is a statement
// about the agent, not about this client -- both are mirrored here like any
// other. Reading it as "no mirror expected" would punch a hole in exactly the
// check this test exists to be.
@Test func everyPublishedVocabularyIsChecked() throws {
    let published = Set(try loadManifest().vocabularies.keys)
    let checked = Set(vocabularyChecks.keys)

    #expect(published.subtracting(checked).isEmpty,
            "the contract publishes vocabularies nothing here checks: \(published.subtracting(checked).sorted())")
    #expect(checked.subtracting(published).isEmpty,
            "checks here name vocabularies the contract no longer publishes: \(checked.subtracting(published).sorted())")
}

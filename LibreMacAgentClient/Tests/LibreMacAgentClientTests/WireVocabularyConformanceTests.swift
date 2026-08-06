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

private func expectMirrorsContract<T: WireNumericMirror>(
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

@Test func errorCodeMirrorsTheContract() throws {
    try expectMirrorsContract(ErrorCode.self, "error-code")
}

@Test func credentialVerbMirrorsTheContract() throws {
    let vocab = try #require(try loadManifest().vocabularies["cred-verb"])
    let tokens = try #require(vocab.tokens)
    #expect(Set(CredentialVerb.allCases.map(\.rawValue)) == Set(tokens))
}

@Test func credentialOutcomeMirrorsTheContract() throws {
    let vocab = try #require(try loadManifest().vocabularies["cred-outcome"])
    let tokens = try #require(vocab.tokens)
    #expect(Set(CredentialOutcome.allCases.map(\.rawValue)) == Set(tokens))
}

@Test func syncErrorMirrorsTheContract() throws {
    let vocab = try #require(try loadManifest().vocabularies["sync-error"])
    let tokens = try #require(vocab.tokens)
    #expect(Set(SyncError.allCases.map(\.rawValue)) == Set(tokens))
}

@Test func credentialKindMirrorsTheContract() throws {
    let vocab = try #require(try loadManifest().vocabularies["cred-kind"])
    #expect(Set(CredentialKind.allCases.map(\.rawValue)) == Set(try #require(vocab.tokens)))
}

@Test func credentialStateMirrorsTheContract() throws {
    let vocab = try #require(try loadManifest().vocabularies["cred-state"])
    #expect(Set(CredentialState.allCases.map(\.rawValue)) == Set(try #require(vocab.tokens)))
}

@Test func unblockStyleMirrorsTheContract() throws {
    let vocab = try #require(try loadManifest().vocabularies["unblock-style"])
    #expect(Set(CredentialUnblockStyle.allCases.map(\.rawValue)) == Set(try #require(vocab.tokens)))
}

@Test func credentialRecoveryMirrorsTheContract() throws {
    let vocab = try #require(try loadManifest().vocabularies["cred-recovery"])
    #expect(Set(CredentialRecovery.allCases.map(\.rawValue)) == Set(try #require(vocab.tokens)))
}

@Test func settableConfigKeyMirrorsTheContract() throws {
    let vocab = try #require(try loadManifest().vocabularies["settable-config-key"])
    #expect(Set(SettableConfigKey.allCases.map(\.rawValue)) == Set(try #require(vocab.tokens)))
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

private func expectRequestFormMirrorsContract<T: CaseIterable & RawRepresentable>(
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

@Test func signatureFormatMirrorsTheContract() throws {
    try expectRequestFormMirrorsContract(SignatureFormat.self, "sign-format")
}

@Test func signatureLevelMirrorsTheContract() throws {
    try expectRequestFormMirrorsContract(SignatureLevel.self, "sign-level")
}

@Test func packagingMirrorsTheContract() throws {
    try expectRequestFormMirrorsContract(Packaging.self, "packaging-mode")
}

// The remaining numeric mirrors. Discovery is all-or-nothing, so the manifest
// carries these from its first commit -- there is no staged half where they are
// absent.

@Test func operationPhaseMirrorsTheContract() throws {
    try expectMirrorsContract(OperationPhase.self, "op-phase")
}

@Test func operationStatusMirrorsTheContract() throws {
    try expectMirrorsContract(OperationStatus.self, "op-status")
}

@Test func preReadAuthMirrorsTheContract() throws {
    try expectMirrorsContract(PreReadAuth.self, "pre-read-auth")
}

@Test func quiesceReasonMirrorsTheContract() throws {
    try expectMirrorsContract(QuiesceReason.self, "quiesce-reason")
}

private struct BitPair: Hashable {
    let bit: UInt32
    let name: String
}

@Test func capabilityBitsMirrorTheContract() throws {
    // The published values are bit INDICES (Pki: 0, IdentityData: 1, ...),
    // matching `Capabilities.Bit`'s raw values -- not the 1/2/4/8 masks the
    // OptionSet members carry.
    let entries = try #require(try loadManifest().vocabularies["capability-bit"]?.numeric)

    let declared = Set(Capabilities.Bit.allCases.map { BitPair(bit: $0.rawValue, name: $0.wireName) })
    let published = Set(entries.map { BitPair(bit: $0.value, name: $0.name) })
    #expect(declared == published)
}

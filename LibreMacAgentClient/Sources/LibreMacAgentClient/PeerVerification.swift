// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation
import Security
import os

/// Decides, on a CONNECTED AF_UNIX fd, whether the process serving the other
/// end is one this client may speak to. Runs after `connect()` and before the
/// first byte is written; `false` closes the connection unused.
public typealias PeerVerifier = @Sendable (Int32) -> Bool

/// The code-signing facts of a peer, read from its audit token through the
/// public SecTask API, plus — when a team id is configured — whether its code
/// satisfies the designated requirement. Same shape as the agent's own
/// resolution of its peers, so both ends judge by the same facts.
public struct PeerCodeSigning: Sendable, Equatable {
    /// `SecTaskCopySigningIdentifier`; nil for a peer that could not be read.
    public var signingId: String?
    /// `com.apple.security.application-groups`.
    public var appGroups: [String]
    /// nil: not evaluated (no team id). false: evaluated and failed, or the
    /// peer's code could not be reached. true: `SecCodeCheckValidity` held.
    public var designatedRequirementValid: Bool?

    public init(signingId: String?, appGroups: [String], designatedRequirementValid: Bool? = nil) {
        self.signingId = signingId
        self.appGroups = appGroups
        self.designatedRequirementValid = designatedRequirementValid
    }
}

/// The identity the agent must present: its signing identifier and the App
/// Group entitlement. Both are CLAIMED by the peer's own signature, and an
/// ad-hoc signed binary can claim both, so without a team id this keeps the
/// client from talking to a stranger by accident, not to one that signs itself
/// to match. With a team id the peer must also satisfy the designated
/// requirement, which only a binary our team signed can.
public struct ExpectedPeerIdentity: Sendable, Equatable {
    public var signingId: String
    public var appGroup: String
    public var teamId: String?

    public init(signingId: String, appGroup: String, teamId: String? = nil) {
        self.signingId = signingId
        self.appGroup = appGroup
        self.teamId = teamId
    }
}

public enum AgentPeerIdentity {
    /// The agent's code-signing identifier (`Scripts/bundle-agent.sh` signs it
    /// with exactly this).
    public static let signingId = "org.librescrs.agent"

    /// The team every LibreSCRS binary is signed by. Empty while the builds are
    /// signed ad hoc, which keeps the check to identifier and App Group. It is
    /// compiled in, never read from the environment or a file: anything a
    /// process can be handed at launch could switch the check off. It changes
    /// together with `DEVELOPMENT_TEAM` in `project.yml` (a test holds the two
    /// equal) and with the agent's own `LIBRESCRS_TEAM_ID`.
    static let configuredTeamIdentifier = ""

    /// `configuredTeamIdentifier`, nil when empty.
    public static var configuredTeamId: String? {
        configuredTeamIdentifier.isEmpty ? nil : configuredTeamIdentifier
    }

    /// What the agent must present to this build.
    public static var expected: ExpectedPeerIdentity {
        ExpectedPeerIdentity(
            signingId: signingId, appGroup: AgentSocketPath.appGroupIdentifier, teamId: configuredTeamId)
    }
}

private let peerLogger = os.Logger(subsystem: "org.librescrs.LibreMac", category: "agent")

/// The verifier production clients use: the serving process must present the
/// agent's signing identifier and the App Group, and — with a team id — satisfy
/// the designated requirement. Fails closed on anything it cannot read, and
/// logs why it refused.
public func defaultPeerVerifier(
    expectedSigningId: String = AgentPeerIdentity.signingId,
    appGroup: String = AgentSocketPath.appGroupIdentifier,
    teamId: String? = AgentPeerIdentity.configuredTeamId
) -> PeerVerifier {
    let expected = ExpectedPeerIdentity(signingId: expectedSigningId, appGroup: appGroup, teamId: teamId)
    return { fd in verifyConnectedPeer(fd, expected: expected) }
}

/// The designated requirement for `signingId` signed by `teamId`, or nil when
/// either is empty or carries anything but letters, digits and (for the
/// identifier) `.`, `-`, `_` — both are pasted into the requirement language,
/// so a quote or a space could add a clause. Same text as the agent's.
public func designatedRequirement(teamId: String, signingId: String) -> String? {
    func isPlain(_ text: String, extra: Set<Character>) -> Bool {
        !text.isEmpty && text.allSatisfy { c in
            (c.isASCII && (c.isLetter || c.isNumber)) || extra.contains(c)
        }
    }
    guard isPlain(teamId, extra: []), isPlain(signingId, extra: [".", "-", "_"]) else { return nil }
    return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamId)\" and identifier \"\(signingId)\""
}

/// Policy: does `peer` present `expected`? Pure, so it is testable without
/// real signing.
public func matchesExpectedPeer(_ peer: PeerCodeSigning, _ expected: ExpectedPeerIdentity) -> Bool {
    guard let signingId = peer.signingId, signingId == expected.signingId else { return false }
    if expected.teamId != nil, peer.designatedRequirementValid != true {
        return false // not evaluated counts as failed
    }
    return peer.appGroups.contains(expected.appGroup)
}

/// The audit token of the process at the other end of a connected AF_UNIX fd
/// (`LOCAL_PEERTOKEN` reports it from either end, so a client can read the
/// process serving the socket it connected to). nil when it cannot be read.
func peerAuditToken(_ fd: Int32) -> audit_token_t? {
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    let rc = withUnsafeMutablePointer(to: &token) { pointer in
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, pointer, &length)
    }
    guard rc == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
    return token
}

/// The peer's SecTask facts, and with `teamId` the designated-requirement
/// verdict for the identifier SecTask reported. An unreadable peer yields no
/// signing id and no groups, which every policy refuses.
public func resolvePeerCodeSigning(auditToken: audit_token_t, teamId: String?) -> PeerCodeSigning {
    var out = PeerCodeSigning(signingId: nil, appGroups: [], designatedRequirementValid: teamId == nil ? nil : false)
    guard let task = SecTaskCreateWithAuditToken(nil, auditToken) else {
        peerLogger.error("cannot read the code signature of the process serving the agent socket (no SecTask for its audit token)")
        return out
    }
    out.signingId = SecTaskCopySigningIdentifier(task, nil) as String?
    if let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        as? [String]
    {
        out.appGroups = groups
    }
    if let teamId, let signingId = out.signingId {
        out.designatedRequirementValid = peerSatisfiesDesignatedRequirement(
            auditToken: auditToken, teamId: teamId, signingId: signingId)
    }
    return out
}

/// Capture, resolve and match in one step. Fails closed when the peer cannot
/// be captured or read; logs every refusal with what the peer presented.
public func verifyConnectedPeer(_ fd: Int32, expected: ExpectedPeerIdentity) -> Bool {
    guard let token = peerAuditToken(fd) else {
        peerLogger.error("refusing the agent socket: the serving process's audit token cannot be read")
        return false
    }
    let peer = resolvePeerCodeSigning(auditToken: token, teamId: expected.teamId)
    guard matchesExpectedPeer(peer, expected) else {
        let presented = peer.signingId ?? "none"
        let hasGroup = peer.appGroups.contains(expected.appGroup)
        let requirement = peer.designatedRequirementValid.map { $0 ? "held" : "failed" } ?? "not checked"
        peerLogger.error(
            "refusing the agent socket: the serving process presents signing id \(presented, privacy: .public) (expected \(expected.signingId, privacy: .public)), app group \(hasGroup ? "present" : "absent", privacy: .public), designated requirement \(requirement, privacy: .public)")
        return false
    }
    return true
}

/// `SecCodeCheckValidity` of the peer's code — reached through its audit token,
/// which carries the pid version, so a reused pid cannot stand in for it —
/// against the designated requirement. Anything that cannot be built or
/// checked is a failure.
private func peerSatisfiesDesignatedRequirement(auditToken: audit_token_t, teamId: String, signingId: String) -> Bool {
    guard let text = designatedRequirement(teamId: teamId, signingId: signingId) else { return false }
    var token = auditToken
    let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
    let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
        return false
    }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

/// The one place a connected fd meets its verifier: hands the fd back when the
/// serving process passes, otherwise closes it — nothing was written on it —
/// and throws `peerRejected`.
func requireVerifiedPeer(_ fd: Int32, verifier: PeerVerifier) throws(SocketConnectionError) -> Int32 {
    guard verifier(fd) else {
        Darwin.close(fd)
        throw .peerRejected
    }
    return fd
}

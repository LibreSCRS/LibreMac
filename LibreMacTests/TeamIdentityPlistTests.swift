// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The clients read the team the agent must be signed by from their own
// Info.plist, and the App Group is named after it. A bundle that lost the key
// would read "no team" and quietly skip the designated-requirement check, and a
// host and extension that disagree would look for the agent in two different
// containers. So the built host and the built token extension must carry the
// same value, one Scripts/generate-project.sh could have accepted.

import Foundation
import LibreMacAgentClient
import Testing

@Suite("Team identity in the built bundle")
struct TeamIdentityPlistTests {

    private static func hostTeamId() throws -> String {
        try #require(
            Bundle.main.object(forInfoDictionaryKey: AgentPeerIdentity.teamIdInfoKey) as? String,
            "the host Info.plist carries \(AgentPeerIdentity.teamIdInfoKey)")
    }

    @Test("the host's team is empty or upper-case letters and digits")
    func hostTeamIsWellFormed() throws {
        let team = try Self.hostTeamId()
        #expect(team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }, "got '\(team)'")
    }

    @Test("host and token extension carry the same team")
    func bothBundlesCarryTheSameTeam() throws {
        let host = try Self.hostTeamId()
        let appexURL = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("LibreMacToken.appex"))
        let appex = try #require(Bundle(url: appexURL), "the token extension is embedded in the host")
        #expect(appex.object(forInfoDictionaryKey: AgentPeerIdentity.teamIdInfoKey) as? String == host)
    }
}

// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The clients read the team the agent must be signed by from their own
// Info.plist. A bundle that lost the key would read "no team" and quietly skip
// the designated-requirement check, so the built host and the built token
// extension must both carry it, with the value project.yml states.

import Foundation
import LibreMacAgentClient
import Testing

@Suite("Team identity in the built bundle")
struct TeamIdentityPlistTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The one `LIBRESCRS_TEAM_ID:` value in project.yml, unquoted.
    private static func projectTeamId() throws -> String {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let values = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("LIBRESCRS_TEAM_ID:") else { return nil }
            return trimmed.dropFirst("LIBRESCRS_TEAM_ID:".count)
                .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        try #require(values.count == 1, "project.yml states LIBRESCRS_TEAM_ID exactly once")
        return values[0]
    }

    @Test("host and token extension both carry LibreSCRSTeamID, equal to project.yml")
    func bothBundlesCarryTheTeam() throws {
        let expected = try Self.projectTeamId()
        #expect(expected.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) })

        let host = Bundle.main.object(forInfoDictionaryKey: AgentPeerIdentity.teamIdInfoKey) as? String
        #expect(host == expected)

        let appexURL = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("LibreMacToken.appex"))
        let appex = try #require(Bundle(url: appexURL), "the token extension is embedded in the host")
        #expect(appex.object(forInfoDictionaryKey: AgentPeerIdentity.teamIdInfoKey) as? String == expected)
    }
}

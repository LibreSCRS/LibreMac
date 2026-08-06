// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The trust pane's pure parts: the address check that runs before a request
// is sent, and the wire shape of a trusted-list source.

import Foundation
import LibreMacAgentClient
import Testing

@testable import LibreMac

@Suite("Trust pane")
struct TrustPaneTests {

    /// The check exists to catch a typo before it becomes a request, not to
    /// decide policy — the agent does that, and may still refuse what passes
    /// here.
    @Test("an address without a host or a web scheme is not offered to the agent")
    func addressCheckRejectsTheUnusable() {
        #expect(isUsableTrustUrl("https://tsa.example/tsa"))
        #expect(isUsableTrustUrl("http://tsa.example"))
        #expect(isUsableTrustUrl("  https://tsa.example/  "), "surrounding space is a paste artefact")

        #expect(!isUsableTrustUrl(""))
        #expect(!isUsableTrustUrl("tsa.example"), "no scheme")
        #expect(!isUsableTrustUrl("https://"), "no host")
        #expect(!isUsableTrustUrl("ftp://tsa.example/"), "not a web scheme")
        #expect(!isUsableTrustUrl("file:///etc/passwd"), "not a web scheme")
    }

    @Test("a source round-trips through the wire shape with both flags")
    func sourceRoundTrips() {
        for source in [
            TslSource(url: "https://lotl.example/", isLotl: true, eager: true),
            TslSource(url: "https://plain.example/", isLotl: false, eager: false),
            TslSource(url: "https://mixed.example/", isLotl: true, eager: false),
        ] {
            #expect(TslSource(cbor: source.cbor) == source)
        }
    }

    /// Both flags are written even when false. A reader cannot tell an absent
    /// key from a false one, so a round-trip that omitted them would be free
    /// to change what the computer trusts on the way back.
    @Test("both flags are present on the wire even when false")
    func flagsAreAlwaysWritten() {
        guard case .map(let pairs) = TslSource(url: "https://plain.example/").cbor else {
            Issue.record("a source must encode as a map")
            return
        }
        let keys = Set(pairs.map { String(decoding: $0.0, as: UTF8.self) })
        #expect(keys == ["url", "isLotl", "eager"])
    }

    @Test("a map without a url is not a source")
    func mapWithoutUrlIsNotASource() {
        #expect(TslSource(cbor: .map([(Data("eager".utf8), .bool(true))])) == nil)
        #expect(TslSource(cbor: .map([(Data("url".utf8), .text(""))])) == nil)
        #expect(TslSource(cbor: .text("https://not-a-map.example/")) == nil)
    }
}

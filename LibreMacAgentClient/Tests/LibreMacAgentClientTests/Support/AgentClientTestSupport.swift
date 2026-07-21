// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import Testing
@testable import LibreMacAgentClient

/// Builds an `AgentClient` wired to `mock` via the package's internal
/// `connector`-taking initializer, with short timeouts/backoff so tests
/// run fast without ever needing a real elapsed-time sleep as
/// synchronization.
func makeTestClient(
    mock: MockAgentServer,
    propTimeout: TimeInterval = 1,
    discoveryTimeout: TimeInterval = 1,
    initialBackoff: TimeInterval = 0.05,
    maxBackoff: TimeInterval = 0.2
) -> AgentClient {
    AgentClient(
        connector: { try mock.connect() },
        clientVersion: "LibreMac/test",
        propTimeout: propTimeout,
        discoveryTimeout: discoveryTimeout,
        initialBackoff: initialBackoff,
        maxBackoff: maxBackoff)
}

/// Answers the mandatory `Hello` -> `GetState` handshake every connection
/// attempt starts with (Hello first, always, by protocol convention).
/// Fails the test via
/// `Issue.record` if the two requests don't arrive in that order.
func answerHandshake(
    _ mock: MockAgentServer,
    _ iterator: inout AsyncStream<DecodedRequest>.AsyncIterator,
    agentVersion: String = "1.0.0-test",
    features: [String] = [],
    readers: [ReaderState] = [],
    cards: [CardState] = [],
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    guard let hello = await iterator.next() else {
        Issue.record("expected a Hello request, got none", sourceLocation: sourceLocation)
        return
    }
    guard case .hello(let proto, _) = hello.request else {
        Issue.record("expected Hello first, got \(hello.request)", sourceLocation: sourceLocation)
        return
    }
    #expect(proto == UInt64(kProtocolVersion), sourceLocation: sourceLocation)
    mock.sendReply(.helloAck(agentVer: agentVersion, features: features), req: hello.req)

    guard let getState = await iterator.next() else {
        Issue.record("expected a GetState request, got none", sourceLocation: sourceLocation)
        return
    }
    guard case .getState = getState.request else {
        Issue.record("expected GetState second, got \(getState.request)", sourceLocation: sourceLocation)
        return
    }
    mock.sendReply(.state(readers: readers, cards: cards), req: getState.req)
}

/// `start()`s `client` against `mock` and drives the initial handshake,
/// returning the shared request iterator so the caller can keep consuming
/// requests from exactly where the handshake left off. `features` is the
/// `HelloAck.features` token list the mock advertises — the default `[]`
/// stands in for an older agent that predates every feature token.
func startAndHandshake(
    _ mock: MockAgentServer,
    _ client: AgentClient,
    features: [String] = [],
    readers: [ReaderState] = [],
    cards: [CardState] = [],
    sourceLocation: SourceLocation = #_sourceLocation
) async -> AsyncStream<DecodedRequest>.AsyncIterator {
    await client.start()
    var iterator = mock.requests.makeAsyncIterator()
    await answerHandshake(
        mock, &iterator, features: features, readers: readers, cards: cards, sourceLocation: sourceLocation)
    return iterator
}

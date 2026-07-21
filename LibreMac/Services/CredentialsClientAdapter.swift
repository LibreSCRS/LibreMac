// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// The composition root's `AgentCredentialsClient`: the four credential ops
// and the feature flag forward to the app's shared `AgentClient`, while the
// two event streams come from `CardMonitor`'s forwarding taps —
// `AgentClient.registryUpdates` / `quiescence` are UNICAST `AsyncStream`s
// already consumed by `CardMonitor`, so the app's one client must NOT also
// feed `CredentialsViewModel` directly (see the conformance note on
// `extension AgentClient: AgentCredentialsClient`). The app instantiates
// exactly ONE `CredentialsViewModel` over one instance of this adapter; the
// taps are themselves unicast, and that view model is their one consumer.

import LibreMacAgentClient

struct CredentialsClientAdapter: AgentCredentialsClient {
    private let client: AgentClient
    let registryUpdates: AsyncStream<RegistrySnapshot>
    let quiescence: AsyncStream<QuiesceReason>

    @MainActor
    init(client: AgentClient, monitor: CardMonitor) {
        self.client = client
        self.registryUpdates = monitor.registryUpdatesTap
        self.quiescence = monitor.quiescenceTap
    }

    var supportsCredentials: Bool {
        get async { await client.supportsCredentials }
    }

    func listCredentials(card: String) async throws -> AgentOperation {
        try await client.listCredentials(card: card)
    }

    func managePin(
        card: String, pinId: String, verb: CredentialVerb, activateKey: Bool
    ) async throws -> AgentOperation {
        try await client.managePin(
            card: card, pinId: pinId, verb: verb, activateKey: activateKey)
    }

    func activateSigningKey(card: String) async throws -> AgentOperation {
        try await client.activateSigningKey(card: card)
    }
}

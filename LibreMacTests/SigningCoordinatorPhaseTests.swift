// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Phase-driving stage-gating for SigningCoordinator. These cases feed an
// `AgentOperation` directly, which requires the package's internal mutators
// (`publishPhase` / `publishResult` / `resolveFinished`) — hence
// `@testable import LibreMacAgentClient`. The `AgentClient`'s own socket cannot
// be spun up in a host unit test, so driving the operation object is the
// faithful stand-in for the wire events an agent would emit.

import Darwin
import Foundation
import Testing
@testable import LibreMacAgentClient
@testable import LibreMac

@MainActor
private func waitUntil(
    timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

@Suite("SigningCoordinator phases")
@MainActor
struct SigningCoordinatorPhaseTests {

    @Test("awaitingConsent phase renders the consent stage; error finishes failed")
    func consentThenFailure() async {
        let operation = AgentOperation(id: 1, kind: .sign, cancelHandler: {})
        let client = MockSigningClient(.returnOperation(operation))
        let coordinator = SigningCoordinator(client: client)
        let input = makeTempFile()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString)")

        let signTask = Task {
            await coordinator.sign(
                card: "card:0", certId: "cert:0", inputURL: input, destinationURL: output)
        }

        #expect(await waitUntil { client.signCallCount == 1 })
        operation.publishPhase(.awaitingConsent, progress: nil)
        #expect(await waitUntil { coordinator.stage == .awaitingConsent })

        operation.resolveFinished((.error, .authFailed, nil, "auth failed"))
        #expect(await waitUntil {
            if case .failed = coordinator.stage { return true }
            return false
        })
        await signTask.value
    }

    @Test("an unrecognized (future) phase never regresses the rendered stage")
    func unrecognizedPhaseHoldsStage() async {
        let operation = AgentOperation(id: 3, kind: .sign, cancelHandler: {})
        let client = MockSigningClient(.returnOperation(operation))
        let coordinator = SigningCoordinator(client: client)
        let input = makeTempFile()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString)")

        let signTask = Task {
            await coordinator.sign(
                card: "card:0", certId: "cert:0", inputURL: input, destinationURL: output)
        }

        #expect(await waitUntil { client.signCallCount == 1 })
        operation.publishPhase(.awaitingConsent, progress: nil)
        #expect(await waitUntil { coordinator.stage == .awaitingConsent })

        // A future agent reports a phase this build has no case for — the
        // rendered stage must hold at .awaitingConsent, not regress.
        operation.publishPhase(.unknown(99), progress: nil)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(coordinator.stage == .awaitingConsent)

        operation.resolveFinished((.error, .authFailed, nil, "auth failed"))
        #expect(await waitUntil {
            if case .failed = coordinator.stage { return true }
            return false
        })
        await signTask.value
    }

    @Test("a successful sign copies the artifact fd to the destination")
    func successCopiesArtifact() async {
        let operation = AgentOperation(id: 2, kind: .sign, cancelHandler: {})
        let client = MockSigningClient(.returnOperation(operation))
        let coordinator = SigningCoordinator(client: client)
        let input = makeTempFile("to be signed")

        // A real fd standing in for the artifact the agent hands back.
        let artifactURL = makeTempFile("SIGNED-ARTIFACT-BYTES")
        let artifactFd = open(artifactURL.path, O_RDONLY)
        #expect(artifactFd >= 0)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).p7s")

        let signTask = Task {
            await coordinator.sign(
                card: "card:0", certId: "cert:0", inputURL: input, destinationURL: output)
        }

        #expect(await waitUntil { client.signCallCount == 1 })
        let meta = SignMeta(format: "CAdES", level: "B-B", tsaUsed: false, chainComplete: true)
        operation.publishResult(.sign(SignResult(artifact: 0, meta: meta)), fds: [artifactFd])
        operation.resolveFinished((.ok, .none, nil, "signed"))

        #expect(await waitUntil {
            if case .done = coordinator.stage { return true }
            return false
        })
        await signTask.value

        let written = try? String(contentsOf: output, encoding: .utf8)
        #expect(written == "SIGNED-ARTIFACT-BYTES")
    }
}

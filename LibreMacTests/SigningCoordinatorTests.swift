// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Behavioural stage-gating for SigningCoordinator over a mock agent client.
// The PIN never enters this process: there is no PIN stage to gate;
// the subject is the phase → stage mapping and the terminal outcomes. This
// file uses only the public `AgentSigningClient` seam (client-error path +
// reset); the phase-driving cases that need to feed an `AgentOperation` live in
// `SigningCoordinatorPhaseTests`.

import Darwin
import Foundation
import Testing
@testable import LibreMacAgentClient
@testable import LibreMac

/// Mock `AgentSigningClient` that either throws a client error or hands back a
/// caller-supplied operation to drive.
final class MockSigningClient: AgentSigningClient, @unchecked Sendable {
    enum Behavior {
        case throwError(AgentClientError)
        case returnOperation(AgentOperation)
    }

    private let lock = NSLock()
    private let behavior: Behavior
    private var calls = 0
    private var lastOptions: SignOptions?

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    // `NSLock.lock()`/`unlock()` are `noasync`; funnel every use through this
    // synchronous helper so the `async` `sign` never calls them directly.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var signCallCount: Int {
        withLock { calls }
    }

    var lastRequestedOptions: SignOptions? {
        withLock { lastOptions }
    }

    func sign(
        card: String, certId: String, input: FileHandle, options: SignOptions
    ) async throws -> AgentOperation {
        withLock { calls += 1 }
        withLock { lastOptions = options }
        switch behavior {
        case .throwError(let error):
            throw error
        case .returnOperation(let operation):
            return operation
        }
    }
}

/// Writes a temporary file with `contents` and returns its URL.
@MainActor
func makeTempFile(_ contents: String = "payload") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("libremac-t7-\(UUID().uuidString)")
    try? contents.data(using: .utf8)!.write(to: url)
    return url
}

/// Builds an `AgentOperation` already resolved to a successful sign carrying
/// `meta`, so `await coordinator.sign(...)` can drive it straight through
/// without a separate task publishing phases (`finished()` returns
/// immediately once already resolved — see `SigningCoordinatorPhaseTests`
/// for the live-phase variant of the same construction). The artifact fd is
/// a real, readable temp file: `claimResultFileHandle` returns `nil` for an
/// empty fd table, which would misroute this into `.failed`.
@MainActor
func makeCompletedSignOperation(meta: SignMeta) -> AgentOperation {
    let operation = AgentOperation(id: 0, kind: .sign, cancelHandler: {})
    let artifactURL = makeTempFile("SIGNED-ARTIFACT-BYTES")
    let artifactFd = open(artifactURL.path, O_RDONLY)
    #expect(artifactFd >= 0)
    operation.publishResult(.sign(SignResult(artifact: 0, meta: meta)), fds: [artifactFd])
    operation.resolveFinished((.ok, .none, nil, "signed"))
    return operation
}

@Suite("SigningCoordinator")
@MainActor
struct SigningCoordinatorTests {

    @Test("a client that cannot connect drives the stage to failed")
    func clientErrorDrivesFailed() async {
        let client = MockSigningClient(.throwError(.notConnected))
        let coordinator = SigningCoordinator(client: client)
        let input = makeTempFile()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString)")

        await coordinator.sign(
            card: "card:0", certId: "cert:0", inputURL: input, destinationURL: output)

        #expect(client.signCallCount == 1)
        if case .failed(let message) = coordinator.stage {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected .failed, got \(coordinator.stage)")
        }
    }

    @Test("an unreadable input fails before the client is ever called")
    func unreadableInputFailsEarly() async {
        let client = MockSigningClient(.throwError(.notConnected))
        let coordinator = SigningCoordinator(client: client)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString)")

        await coordinator.sign(
            card: "card:0", certId: "cert:0", inputURL: missing, destinationURL: output)

        #expect(client.signCallCount == 0)
        if case .failed = coordinator.stage {} else {
            Issue.record("expected .failed, got \(coordinator.stage)")
        }
    }

    @Test("reset returns a terminal stage to idle")
    func resetReturnsToIdle() async {
        let client = MockSigningClient(.throwError(.notConnected))
        let coordinator = SigningCoordinator(client: client)
        let input = makeTempFile()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString)")

        await coordinator.sign(
            card: "card:0", certId: "cert:0", inputURL: input, destinationURL: output)
        #expect(coordinator.stage != .idle)

        coordinator.reset()
        #expect(coordinator.stage == .idle)
    }

    @Test("the menu bar defers the level to the agent")
    func theMenuBarDefersTheLevelToTheAgent() async {
        let client = MockSigningClient(.throwError(.notConnected))
        let coordinator = SigningCoordinator(client: client)
        let input = makeTempFile()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString)")

        await coordinator.sign(
            card: "card:0", certId: "cert:0", inputURL: input, destinationURL: output)

        #expect(client.lastRequestedOptions?.level == .auto)
    }

    @Test @MainActor func theDoneStageCarriesWhatTheAgentActuallyProduced() async {
        let operation = makeCompletedSignOperation(
            meta: SignMeta(format: "cades", level: "b-t", tsaUsed: true, chainComplete: true))
        let coordinator = SigningCoordinator(client: MockSigningClient(.returnOperation(operation)))
        await coordinator.sign(card: "c", certId: "id",
                               inputURL: makeTempFile(), destinationURL: makeTempFile())
        guard case let .done(_, meta) = coordinator.stage else {
            Issue.record("expected .done, got \(coordinator.stage)"); return
        }
        #expect(meta.level == "b-t")
        #expect(meta.tsaUsed)
    }
}

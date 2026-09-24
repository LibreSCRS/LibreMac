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
import LibreMacShared
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
        let destination = makeTempFile()
        await coordinator.sign(card: "c", certId: "id",
                               inputURL: makeTempFile(), destinationURL: destination,
                               replacing: destination)
        guard case let .done(_, meta) = coordinator.stage else {
            Issue.record("expected .done, got \(coordinator.stage)"); return
        }
        #expect(meta.level == "b-t")
        #expect(meta.tsaUsed)
    }
}

// MARK: - Typed paths inside the sandbox

/// Stands in for the App Sandbox, which is not enforced under
/// `CODE_SIGNING_ALLOWED=NO`: an open succeeds only under the roots the
/// entitlements grant (Downloads here) or under a folder whose security scope is
/// currently started, and is refused with EPERM everywhere else — the errno the
/// kernel returns to a sandboxed process. It proves the coordinator's logic
/// (which scope it starts, when it opens, what it says on a refusal); only a
/// signed, sandboxed run can prove the kernel agrees.
@MainActor
final class FakeSandbox {
    private let grantedRoots: [String]
    private var activeScopes: [String] = []
    private(set) var starts = 0
    private(set) var stops = 0
    /// Every value the start seam returned, in order.
    private(set) var startResults: [Bool] = []
    /// When set, a start also runs the REAL `startAccessingSecurityScopedResource`
    /// and records what it returned — the relaunch test needs that answer.
    var callRealStart = false

    init(granting roots: [URL]) {
        grantedRoots = roots.map { Self.canonical($0.path) }
    }

    static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return (parent as NSString).appendingPathComponent(url.lastPathComponent)
    }

    private func permits(_ path: String) -> Bool {
        let target = Self.canonical(path)
        return (grantedRoots + activeScopes).contains { target.hasPrefix($0 + "/") }
    }

    func open(_ path: String, _ flags: Int32) throws -> Int32 {
        guard permits(path) else { throw POSIXError(.EPERM) }
        return try SigningCoordinator.posixOpen(path, flags)
    }

    func start(_ url: URL) -> Bool {
        starts += 1
        let granted = callRealStart ? url.startAccessingSecurityScopedResource() : true
        startResults.append(granted)
        if granted { activeScopes.append(Self.canonical(url.path)) }
        return granted
    }

    func stop(_ url: URL) {
        stops += 1
        if callRealStart { url.stopAccessingSecurityScopedResource() }
        if let index = activeScopes.firstIndex(of: Self.canonical(url.path)) {
            activeScopes.remove(at: index)
        }
    }
}

/// A throwaway home with `Downloads` and `Documents`, plus an empty defaults
/// suite, so no test reads or writes the real ones.
@MainActor
struct SandboxedHome {
    let home: URL
    let downloads: URL
    let documents: URL
    let defaults: UserDefaults

    init() {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("libremac-home-\(UUID().uuidString)")
        downloads = home.appendingPathComponent("Downloads")
        documents = home.appendingPathComponent("Documents")
        for dir in [downloads, documents] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let suite = "libremac-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func file(_ relative: String, _ contents: String = "payload") -> URL {
        let url = home.appendingPathComponent(relative)
        try? contents.data(using: .utf8)!.write(to: url)
        return url
    }

    func coordinator(
        client: AgentSigningClient = MockSigningClient(.throwError(.notConnected)),
        sandbox: FakeSandbox,
        resolveBookmark: @escaping (Data) throws -> (url: URL, isStale: Bool) =
            SigningCoordinator.resolveFolderBookmark,
        makeBookmark: @escaping (URL) throws -> Data = SigningCoordinator.makeFolderBookmark,
        moveItem: @escaping (URL, URL, Bool) throws -> Void = SigningCoordinator.posixRename
    ) -> SigningCoordinator {
        SigningCoordinator(
            client: client,
            defaults: defaults,
            homeDirectory: home,
            downloadsDirectory: downloads,
            openFile: { try sandbox.open($0, $1) },
            startAccessing: { sandbox.start($0) },
            stopAccessing: { sandbox.stop($0) },
            resolveBookmark: resolveBookmark,
            makeBookmark: makeBookmark,
            moveItem: moveItem)
    }

    /// Names in `folder`, hidden ones included — a leftover temporary file is
    /// a dotfile.
    func contents(of folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }
}

@Suite("SigningCoordinator typed paths")
@MainActor
struct SigningCoordinatorTypedPathTests {

    @Test("a typed path inside Downloads is opened and signed")
    func typedPathInsideDownloadsResolves() async throws {
        let env = SandboxedHome()
        let sandbox = FakeSandbox(granting: [env.downloads])
        _ = env.file("Downloads/contract.txt")
        let operation = makeCompletedSignOperation(
            meta: SignMeta(format: "cades", level: "b-b", tsaUsed: false, chainComplete: true))
        let client = MockSigningClient(.returnOperation(operation))
        let coordinator = env.coordinator(client: client, sandbox: sandbox)

        await coordinator.sign(
            card: "c", certId: "id",
            inputPath: "~/Downloads/contract.txt",
            destinationPath: "~/Downloads/contract.p7s")

        guard case let .done(destination, _) = coordinator.stage else {
            Issue.record("expected .done, got \(coordinator.stage)"); return
        }
        #expect(destination.path == env.downloads.appendingPathComponent("contract.p7s").path)
        #expect(client.signCallCount == 1)
        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written == "SIGNED-ARTIFACT-BYTES")
    }

    @Test("a typed path outside the granted scope fails with the permission message")
    func typedPathOutsideScopeFailsWithPermissionMessage() async {
        let env = SandboxedHome()
        let sandbox = FakeSandbox(granting: [env.downloads])
        _ = env.file("Documents/contract.txt")
        _ = env.file("Downloads/contract.txt")
        let client = MockSigningClient(.throwError(.notConnected))
        let coordinator = env.coordinator(client: client, sandbox: sandbox)

        // Input outside the scope: refused before the card is ever asked.
        await coordinator.sign(
            card: "c", certId: "id",
            inputPath: "~/Documents/contract.txt",
            destinationPath: "~/Downloads/contract.p7s")
        #expect(coordinator.stage == .failed(message: SigningCoordinator.notPermittedMessage))
        #expect(client.signCallCount == 0)
        #expect(!FileManager.default.fileExists(
            atPath: env.downloads.appendingPathComponent("contract.p7s").path))

        // Destination outside the scope: also refused BEFORE the card signs —
        // a signature the user confirmed must not be thrown away afterwards.
        coordinator.reset()
        await coordinator.sign(
            card: "c", certId: "id",
            inputPath: "~/Downloads/contract.txt",
            destinationPath: "~/Documents/contract.p7s")
        #expect(coordinator.stage == .failed(message: SigningCoordinator.notPermittedMessage))
        #expect(client.signCallCount == 0)
        #expect(!SigningCoordinator.notPermittedMessage.isEmpty)
    }

    @Test("the destination falls back to Downloads when no bookmark is usable")
    func destinationFallsBackToDownloadsWhenBookmarkMissing() {
        let env = SandboxedHome()
        let sandbox = FakeSandbox(granting: [env.downloads])
        let coordinator = env.coordinator(sandbox: sandbox)
        let input = env.documents.appendingPathComponent("contract.pdf")
        let expected = env.downloads.appendingPathComponent("contract.p7s").path

        // Nothing configured: Downloads, and nothing to apologise for.
        let plain = coordinator.proposedDestination(forInput: input)
        #expect(plain.url.path == expected)
        #expect(!plain.fellBackToDownloads)

        // A folder configured by typing, with no bookmark, outside the scope.
        env.defaults.set(env.documents.path,
                         forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolder)
        let typed = coordinator.proposedDestination(forInput: input)
        #expect(typed.url.path == expected)
        #expect(typed.fellBackToDownloads)

        // A bookmark that no longer resolves.
        env.defaults.set(Data("not a bookmark".utf8),
                         forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolderBookmark)
        let broken = coordinator.proposedDestination(forInput: input)
        #expect(broken.url.path == expected)
        #expect(broken.fellBackToDownloads)
        #expect(sandbox.starts == sandbox.stops)
    }

    @Test("a bookmarked folder resolves and is writable after a relaunch")
    func bookmarkedFolderResolvesAfterRelaunch() async throws {
        let env = SandboxedHome()
        let chosen = env.home.appendingPathComponent("Signed")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        // First launch: the folder is chosen and remembered.
        try SigningCoordinator.rememberOutputFolder(chosen, in: env.defaults)
        #expect(env.defaults.data(
            forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolderBookmark) != nil)

        // Relaunch: a new coordinator over the same defaults, with only the
        // serialized bookmark to go on.
        let sandbox = FakeSandbox(granting: [env.downloads])
        sandbox.callRealStart = true
        _ = env.file("Downloads/contract.txt")
        let operation = makeCompletedSignOperation(
            meta: SignMeta(format: "cades", level: "b-b", tsaUsed: false, chainComplete: true))
        let coordinator = env.coordinator(
            client: MockSigningClient(.returnOperation(operation)), sandbox: sandbox)

        let proposal = coordinator.proposedDestination(
            forInput: env.downloads.appendingPathComponent("contract.txt"))
        #expect(FakeSandbox.canonical(proposal.url.path)
                == FakeSandbox.canonical(chosen.appendingPathComponent("contract.p7s").path))
        #expect(!proposal.fellBackToDownloads)
        #expect(sandbox.startResults.first == true)

        await coordinator.sign(
            card: "c", certId: "id",
            inputPath: "~/Downloads/contract.txt",
            destinationPath: proposal.url.path)
        guard case let .done(destination, _) = coordinator.stage else {
            Issue.record("expected .done, got \(coordinator.stage)"); return
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(sandbox.startResults.allSatisfy { $0 })
        #expect(sandbox.starts == sandbox.stops)
    }

    @Test("a stale bookmark is re-created while its scope is open")
    func staleBookmarkIsRefreshed() {
        let env = SandboxedHome()
        let chosen = env.home.appendingPathComponent("Signed")
        try? FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        env.defaults.set(chosen.path, forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolder)
        env.defaults.set(Data("old".utf8),
                         forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolderBookmark)
        let sandbox = FakeSandbox(granting: [env.downloads])
        var remadeWhileOpen: Bool?
        let coordinator = env.coordinator(
            sandbox: sandbox,
            resolveBookmark: { _ in (chosen, true) },
            makeBookmark: { _ in
                remadeWhileOpen = sandbox.starts > sandbox.stops
                return Data("fresh".utf8)
            })

        let proposal = coordinator.proposedDestination(
            forInput: env.downloads.appendingPathComponent("contract.txt"))

        #expect(!proposal.fellBackToDownloads)
        #expect(remadeWhileOpen == true)
        #expect(env.defaults.data(
            forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolderBookmark)
                == Data("fresh".utf8))
        #expect(sandbox.starts == sandbox.stops)
    }

    // MARK: Never overwrite silently

    @Test("the destination may not be the input, by path or by identity")
    func sameFileAsInputIsRefused() async throws {
        let env = SandboxedHome()
        let sandbox = FakeSandbox(granting: [env.downloads])
        let input = env.file("Downloads/x.p7s", "ORIGINAL")
        let client = MockSigningClient(.throwError(.notConnected))
        let coordinator = env.coordinator(client: client, sandbox: sandbox)
        let refusal = AppLocalization.shared.loc(
            "libremac_sign_dest_is_input",
            "The signed file cannot replace the file being signed. Choose another name.")

        // The same path under another spelling, even with replace allowed.
        await coordinator.sign(
            card: "c", certId: "id", inputPath: "~/Downloads/x.p7s",
            destinationPath: "~/Downloads/../Downloads/x.p7s", replacing: input)
        #expect(coordinator.stage == .failed(message: refusal))

        // A hard link: another path, the same file.
        let link = env.downloads.appendingPathComponent("link.p7s")
        try FileManager.default.linkItem(at: input, to: link)
        coordinator.reset()
        await coordinator.sign(
            card: "c", certId: "id", inputPath: "~/Downloads/x.p7s",
            destinationPath: "~/Downloads/link.p7s", replacing: link)
        #expect(coordinator.stage == .failed(message: refusal))

        #expect(client.signCallCount == 0)
        #expect(try String(contentsOf: input, encoding: .utf8) == "ORIGINAL")
    }

    @Test("an existing destination is replaced only after confirmation")
    func existingDestinationNeedsConfirmation() async throws {
        let env = SandboxedHome()
        let sandbox = FakeSandbox(granting: [env.downloads])
        _ = env.file("Downloads/contract.txt")
        let existing = env.file("Downloads/contract.p7s", "OLD")
        let operation = makeCompletedSignOperation(
            meta: SignMeta(format: "cades", level: "b-b", tsaUsed: false, chainComplete: true))
        let client = MockSigningClient(.returnOperation(operation))
        let coordinator = env.coordinator(client: client, sandbox: sandbox)

        await coordinator.sign(
            card: "c", certId: "id", inputPath: "~/Downloads/contract.txt",
            destinationPath: "~/Downloads/contract.p7s")
        guard case let .confirmReplace(destination) = coordinator.stage else {
            Issue.record("expected .confirmReplace, got \(coordinator.stage)"); return
        }
        #expect(destination.path == existing.path)
        #expect(client.signCallCount == 0)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "OLD")

        await coordinator.sign(
            card: "c", certId: "id", inputPath: "~/Downloads/contract.txt",
            destinationPath: "~/Downloads/contract.p7s", replacing: destination)
        guard case .done = coordinator.stage else {
            Issue.record("expected .done, got \(coordinator.stage)"); return
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "SIGNED-ARTIFACT-BYTES")
        #expect(env.contents(of: env.downloads) == ["contract.txt", "contract.p7s"])
    }

    @Test("the proposal never names an existing file")
    func proposalPicksAUniqueName() {
        let env = SandboxedHome()
        let sandbox = FakeSandbox(granting: [env.downloads])
        let coordinator = env.coordinator(sandbox: sandbox)
        _ = env.file("Downloads/contract.p7s")
        _ = env.file("Downloads/contract 2.p7s")

        let next = coordinator.proposedDestination(
            forInput: env.documents.appendingPathComponent("contract.pdf"))
        #expect(next.url.lastPathComponent == "contract 3.p7s")

        // Signing a .p7s: the plain proposal would be the input itself.
        let input = env.file("Downloads/x.p7s")
        let own = coordinator.proposedDestination(forInput: input)
        #expect(own.url.lastPathComponent == "x 2.p7s")
    }

    @Test("a failed sign leaves no temporary file and an existing file intact")
    func temporaryFileIsRemovedWhenTheSignFails() async throws {
        let env = SandboxedHome()
        let sandbox = FakeSandbox(granting: [env.downloads])
        _ = env.file("Downloads/contract.txt")

        // The agent fails after the temporary file was created.
        let failing = env.coordinator(
            client: MockSigningClient(.throwError(.notConnected)), sandbox: sandbox)
        await failing.sign(
            card: "c", certId: "id", inputPath: "~/Downloads/contract.txt",
            destinationPath: "~/Downloads/contract.p7s")
        guard case .failed = failing.stage else {
            Issue.record("expected .failed, got \(failing.stage)"); return
        }
        #expect(env.contents(of: env.downloads) == ["contract.txt"])

        // The final rename fails while replacing an existing file.
        let existing = env.file("Downloads/contract.p7s", "OLD")
        let operation = makeCompletedSignOperation(
            meta: SignMeta(format: "cades", level: "b-b", tsaUsed: false, chainComplete: true))
        let renameFails = env.coordinator(
            client: MockSigningClient(.returnOperation(operation)), sandbox: sandbox,
            moveItem: { _, _, _ in throw POSIXError(.EIO) })
        await renameFails.sign(
            card: "c", certId: "id", inputPath: "~/Downloads/contract.txt",
            destinationPath: "~/Downloads/contract.p7s", replacing: existing)
        guard case .failed = renameFails.stage else {
            Issue.record("expected .failed, got \(renameFails.stage)"); return
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "OLD")
        #expect(env.contents(of: env.downloads) == ["contract.txt", "contract.p7s"])
        #expect(sandbox.starts == sandbox.stops)
    }

    @Test("a confirmation replaces only the file it asked about")
    func confirmationIsBoundToTheFileItNamed() async throws {
        let env = SandboxedHome()
        let sandbox = FakeSandbox(granting: [env.downloads])
        _ = env.file("Downloads/contract.txt")
        let first = env.file("Downloads/a.p7s", "A")
        let second = env.file("Downloads/b.p7s", "B")
        let client = MockSigningClient(.throwError(.notConnected))
        let coordinator = env.coordinator(client: client, sandbox: sandbox)

        await coordinator.sign(
            card: "c", certId: "id", inputPath: "~/Downloads/contract.txt",
            destinationPath: "~/Downloads/a.p7s")
        guard case let .confirmReplace(asked) = coordinator.stage else {
            Issue.record("expected .confirmReplace, got \(coordinator.stage)"); return
        }
        #expect(asked.path == first.path)

        // The field now says b.p7s; Replace carries the confirmation for a.p7s.
        await coordinator.sign(
            card: "c", certId: "id", inputPath: "~/Downloads/contract.txt",
            destinationPath: "~/Downloads/b.p7s", replacing: asked)
        #expect(coordinator.stage == .confirmReplace(destination: second))
        #expect(client.signCallCount == 0)
        #expect(try String(contentsOf: second, encoding: .utf8) == "B")
        #expect(try String(contentsOf: first, encoding: .utf8) == "A")
    }

    @Test("a file that appears during the card wait is not replaced without asking")
    func fileAppearingDuringConsentIsNotReplaced() async throws {
        let env = SandboxedHome()
        let sandbox = FakeSandbox(granting: [env.downloads])
        _ = env.file("Downloads/contract.txt")
        let destination = env.downloads.appendingPathComponent("contract.p7s")
        let operation = makeCompletedSignOperation(
            meta: SignMeta(format: "cades", level: "b-b", tsaUsed: false, chainComplete: true))
        let coordinator = env.coordinator(
            client: MockSigningClient(.returnOperation(operation)), sandbox: sandbox,
            moveItem: { from, to, exclusive in
                // Another process takes the name just before the rename.
                try Data("APPEARED".utf8).write(to: to)
                try SigningCoordinator.posixRename(from, to, exclusive)
            })

        await coordinator.sign(
            card: "c", certId: "id", inputPath: "~/Downloads/contract.txt",
            destinationPath: "~/Downloads/contract.p7s")

        #expect(coordinator.stage == .confirmReplace(destination: destination))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "APPEARED")
        #expect(env.contents(of: env.downloads) == ["contract.txt", "contract.p7s"])
    }

    @Test("a folder at the destination is refused before the card is asked")
    func directoryAtDestinationIsRefused() async {
        let env = SandboxedHome()
        let sandbox = FakeSandbox(granting: [env.downloads])
        _ = env.file("Downloads/contract.txt")
        let folder = env.downloads.appendingPathComponent("contract.p7s")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let client = MockSigningClient(.throwError(.notConnected))
        let coordinator = env.coordinator(client: client, sandbox: sandbox)

        // Even with the folder itself "confirmed".
        await coordinator.sign(
            card: "c", certId: "id", inputPath: "~/Downloads/contract.txt",
            destinationPath: "~/Downloads/contract.p7s", replacing: folder)

        #expect(coordinator.stage == .failed(message: AppLocalization.shared.loc(
            "libremac_sign_dest_not_a_file",
            "Something other than a file already has that name. Choose another name.")))
        #expect(client.signCallCount == 0)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
                && isDirectory.boolValue)
        #expect(env.contents(of: env.downloads) == ["contract.txt", "contract.p7s"])
    }
}

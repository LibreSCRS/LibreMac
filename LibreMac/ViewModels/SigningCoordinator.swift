// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// `@Observable` view model that orchestrates a sign over the local agent. The
// PIN never reaches this process (protected authentication path): the
// coordinator only ever observes the operation's phases and renders a
// "confirm in the card dialog" affordance while it sits in awaiting-consent /
// authenticating. On success it copies the signed artifact — handed back as an
// fd over SCM_RIGHTS — to the user-chosen destination.
//
// Paths are typed, not only picked: the system file panel service crashes on
// this OS, so a path the user types has to work on its own. The host runs in
// the App Sandbox, which grants Downloads (by entitlement) and the folders the
// user chose (by security-scoped bookmark). A path is checked by OPENING it
// inside that scope — `FileManager.isReadableFile` answers from the file mode
// and says yes to files the sandbox then refuses.

import Darwin
import Foundation
import LibreMacAgentClient
import LibreMacShared
import Observation
import os

/// The slice of `AgentClient` the coordinator needs. Behind a protocol seam so
/// the stage-gating is unit-testable with an in-memory fake (the concrete
/// `AgentClient` is an actor whose socket cannot be spun up in a host unit
/// test). `AgentClient` conforms below.
public protocol AgentSigningClient: Sendable {
    func sign(
        card: String, certId: String, input: FileHandle, options: SignOptions
    ) async throws -> AgentOperation
}

extension AgentClient: AgentSigningClient {}

@Observable
@MainActor
public final class SigningCoordinator {

    /// Stages aligned to `OperationPhase` — there is no PIN stage.
    public enum Stage: Equatable {
        case idle
        /// Opening the input and starting the operation.
        case preparing
        /// Waiting for the user to approve in the secure card dialog.
        case awaitingConsent
        /// The card / TSA is doing the cryptographic work.
        case working
        /// Signed; payload is where the artifact was written, plus what the
        /// agent actually produced. The level is not necessarily the level
        /// requested: a request that defers resolves against the agent's
        /// configured DefaultLevel, so this is the only honest answer to
        /// "what did I just sign with".
        case done(destination: URL, meta: SignMeta)
        /// Failed; payload is the resolved, user-facing message.
        case failed(message: String)
    }

    public private(set) var stage: Stage = .idle

    private let client: AgentSigningClient
    private let defaults: UserDefaults
    private let homeDirectory: URL
    private let downloadsDirectory: URL
    /// `open(2)`: returns the fd or throws the errno. Every check and every
    /// write goes through here, so a refusal is the kernel's answer.
    private let openFile: (String, Int32) throws -> Int32
    private let startAccessing: (URL) -> Bool
    private let stopAccessing: (URL) -> Void
    private let resolveBookmark: (Data) throws -> (url: URL, isStale: Bool)
    private let makeBookmark: (URL) throws -> Data

    /// The file-system and bookmark calls are parameters so the scope logic
    /// is testable where the sandbox is not enforced (an unsigned test host);
    /// the defaults are the real calls.
    public init(
        client: AgentSigningClient,
        defaults: UserDefaults = .standard,
        homeDirectory: URL = SigningCoordinator.userHomeDirectory,
        downloadsDirectory: URL = SigningCoordinator.userDownloadsDirectory,
        openFile: @escaping (String, Int32) throws -> Int32 = SigningCoordinator.posixOpen,
        startAccessing: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        resolveBookmark: @escaping (Data) throws -> (url: URL, isStale: Bool) =
            SigningCoordinator.resolveFolderBookmark,
        makeBookmark: @escaping (URL) throws -> Data = SigningCoordinator.makeFolderBookmark
    ) {
        self.client = client
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        self.downloadsDirectory = downloadsDirectory
        self.openFile = openFile
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
        self.resolveBookmark = resolveBookmark
        self.makeBookmark = makeBookmark
    }

    /// Default per-sign options. A generic file sign defaults to a detached
    /// CAdES container. The level and the TSA are both owned by agent
    /// configuration, not by this client: pinning a level here would override
    /// whatever the deployment is set up to produce — silently, and at a lower
    /// conformance level.
    public static let defaultOptions = SignOptions(
        format: .cades, level: .auto, packaging: .detached)

    /// Returns the coordinator to `idle` so the UI can start another sign.
    public func reset() {
        if case .done = stage { stage = .idle }
        if case .failed = stage { stage = .idle }
    }

    /// Signs the file at the typed `inputPath`, writing the signed artifact to
    /// the typed `destinationPath`. `~` is the user's home, not the sandbox
    /// container's. A no-op if a sign is already in flight.
    public func sign(
        card: String,
        certId: String,
        inputPath: String,
        destinationPath: String,
        options: SignOptions = SigningCoordinator.defaultOptions
    ) async {
        if isInFlight { return }
        guard let inputURL = resolveInput(path: inputPath),
              let destinationURL = resolveDestination(path: destinationPath)
        else {
            stage = .failed(message: Self.localized(
                "libremac_sign_path_not_absolute",
                "Type a full path, starting with / or ~."))
            return
        }
        await sign(
            card: card, certId: certId, inputURL: inputURL,
            destinationURL: destinationURL, options: options)
    }

    /// Signs `inputURL` with `certId` on `card`, writing the signed artifact to
    /// `destinationURL`. A no-op if a sign is already in flight.
    ///
    /// Both files are opened BEFORE the card is asked: a destination the
    /// sandbox refuses must not surface after the user has confirmed a
    /// signature that then has nowhere to go.
    public func sign(
        card: String,
        certId: String,
        inputURL: URL,
        destinationURL: URL,
        options: SignOptions = SigningCoordinator.defaultOptions
    ) async {
        if isInFlight { return }
        stage = .preparing

        // Start each scope the two paths need once, and stop exactly those
        // that started — on every exit, including the early ones.
        var started: [URL] = []
        defer { started.forEach(stopAccessing) }
        for folder in Set([inputURL, destinationURL].compactMap(scopedFolder(containing:))) {
            if startAccessing(folder) { started.append(folder) }
        }

        let input: FileHandle
        do {
            input = FileHandle(
                fileDescriptor: try openFile(inputURL.path, O_RDONLY), closeOnDealloc: true)
        } catch {
            stage = .failed(message: Self.isPermissionRefusal(error)
                ? Self.notPermittedMessage
                : Self.localized(
                    "libremac_sign_input_unreadable",
                    "The selected file could not be opened for signing."))
            return
        }
        defer { try? input.close() }

        let output: FileHandle
        let createdOutput: Bool
        do {
            (output, createdOutput) = try openDestination(destinationURL)
        } catch {
            stage = .failed(message: Self.isPermissionRefusal(error)
                ? Self.notPermittedMessage
                : Self.writeFailedMessage)
            return
        }
        defer { try? output.close() }
        // An empty file this sign created is removed on every failure below,
        // so a refused or cancelled sign leaves nothing behind.
        var keepOutput = false
        defer {
            if createdOutput && !keepOutput { unlink(destinationURL.path) }
        }

        let operation: AgentOperation
        do {
            operation = try await client.sign(
                card: card, certId: certId, input: input, options: options)
        } catch {
            stage = .failed(message: Self.message(for: error))
            return
        }

        // Drive phases live so the consent affordance appears the moment the
        // agent asks the user to approve. All UI mutation stays on MainActor.
        // Inherits MainActor isolation (created in a MainActor method):
        // `applyPhase` is a same-actor synchronous mutation.
        let phaseTask = Task { [weak self] in
            for await (phase, _) in operation.phases {
                self?.applyPhase(phase)
            }
        }

        let (status, code, _, msgFallback) = await operation.finished()
        phaseTask.cancel()

        guard status == .ok else {
            stage = .failed(message: ErrorCopy.message(for: code, msgFallback: msgFallback))
            return
        }
        guard let signResult = operation.signResult,
              let artifact = operation.claimResultFileHandle(fdIndex: signResult.artifact)
        else {
            stage = .failed(message: Self.localized(
                "libremac_sign_no_artifact",
                "The signature completed but no signed file was returned."))
            return
        }
        // The level shown is whatever the agent actually resolved, never a
        // value this client chose: a request that deferred resolves against
        // the agent's configured default.
        let meta = signResult.meta
        defer { try? artifact.close() }

        do {
            try Self.copyArtifact(from: artifact, to: output)
        } catch {
            stage = .failed(message: Self.writeFailedMessage)
            return
        }
        keepOutput = true

        stage = .done(destination: destinationURL, meta: meta)
        // User-chosen document names are PII — .private per the logging
        // privacy convention (LibreMacShared/Logger+Categories.swift).
        Logger.signing.info(
            "Signed \(inputURL.lastPathComponent, privacy: .private) -> \(destinationURL.lastPathComponent, privacy: .private)")
    }

    private var isInFlight: Bool {
        switch stage {
        case .preparing, .awaitingConsent, .working: return true
        case .idle, .done, .failed: return false
        }
    }

    // MARK: - Typed paths

    /// The URL a typed input path names: trimmed, `~` expanded against the
    /// user's real home, standardized. `nil` for an empty or relative path —
    /// there is no working directory a menu-bar app could mean.
    public func resolveInput(path: String) -> URL? {
        expand(path)
    }

    /// The URL a typed destination path names, by the same rules as the input.
    /// Whether it may be written is decided by opening it inside the scope of
    /// the bookmarked folder when it lies in that folder (`sign`), not here.
    public func resolveDestination(path: String) -> URL? {
        expand(path)
    }

    /// Where the signed copy of `input` is offered: `<folder>/<name>.p7s` in
    /// the default output folder when that folder can be written right now,
    /// otherwise in Downloads. `fellBackToDownloads` is true only when a folder
    /// WAS configured and could not be used, so the UI can say so; an empty
    /// setting means Downloads and needs no apology.
    public func proposedDestination(forInput input: URL) -> (url: URL, fellBackToDownloads: Bool) {
        let name = input.deletingPathExtension().lastPathComponent + ".p7s"
        let configured = (defaults.string(forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolder) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let downloads = downloadsDirectory.appendingPathComponent(name)
        guard !configured.isEmpty else { return (downloads, false) }
        guard let folder = expand(configured) else { return (downloads, true) }
        return canWrite(into: folder)
            ? (folder.appendingPathComponent(name), false)
            : (downloads, true)
    }

    private func expand(_ typed: String) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if trimmed == "~" {
            path = homeDirectory.path
        } else if trimmed.hasPrefix("~/") {
            path = homeDirectory.appendingPathComponent(String(trimmed.dropFirst(2))).path
        } else if trimmed.hasPrefix("/") {
            path = trimmed
        } else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Probes `folder` by creating and removing a file in it, inside the
    /// bookmark's scope when the folder is the bookmarked one.
    private func canWrite(into folder: URL) -> Bool {
        let scope = scopedFolder(containing: folder.appendingPathComponent("probe"))
        let started = scope.map(startAccessing) ?? false
        defer { if started, let scope { stopAccessing(scope) } }
        let probe = folder.appendingPathComponent(".librescrs-write-probe-\(UUID().uuidString)").path
        guard let fd = try? openFile(probe, O_WRONLY | O_CREAT | O_EXCL) else { return false }
        close(fd)
        unlink(probe)
        return true
    }

    /// Opens (creating if needed) the destination for writing, and reports
    /// whether this call created it — only a file this sign created may be
    /// removed when the sign fails.
    private func openDestination(_ url: URL) throws -> (FileHandle, created: Bool) {
        do {
            let fd = try openFile(url.path, O_WRONLY | O_CREAT | O_EXCL)
            return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), true)
        } catch let error as POSIXError where error.code == .EEXIST {
            let fd = try openFile(url.path, O_WRONLY)
            return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), false)
        }
    }

    // MARK: - Default output folder bookmark

    /// The bookmarked default output folder when `url` lies inside it, else
    /// `nil`. A bookmark is used only while it still names the folder the
    /// setting shows: a folder typed over a chosen one is the typed one.
    /// A stale bookmark is re-created inside its own scope, as Apple requires.
    private func scopedFolder(containing url: URL) -> URL? {
        guard let data = defaults.data(forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolderBookmark),
              let resolved = try? resolveBookmark(data)
        else { return nil }
        let folder = resolved.url
        if resolved.isStale, startAccessing(folder) {
            defer { stopAccessing(folder) }
            if let fresh = try? makeBookmark(folder) {
                defaults.set(fresh, forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolderBookmark)
            }
        }
        let shown = defaults.string(forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolder)
            .flatMap(expand)
        guard let shown, Self.canonical(shown) == Self.canonical(folder) else { return nil }
        let target = Self.canonical(url)
        let root = Self.canonical(folder)
        return target.hasPrefix(root + "/") ? folder : nil
    }

    /// Stores `folder` as the default output folder: its path for display and
    /// a security-scoped bookmark so the grant outlives this process. Called
    /// with a URL the panel returned, while that grant is still live.
    public static func rememberOutputFolder(_ folder: URL, in defaults: UserDefaults) throws {
        let data = try makeFolderBookmark(folder)
        defaults.set(folder.path, forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolder)
        defaults.set(data, forKey: AppGroupConstants.DefaultsKeys.defaultOutputFolderBookmark)
    }

    public nonisolated static func makeFolderBookmark(_ folder: URL) throws -> Data {
        try folder.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public nonisolated static func resolveFolderBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    /// A path with its parent's symlinks resolved, so `/var` and
    /// `/private/var`, or the container's `Downloads` link and the real
    /// folder, compare equal even when the file itself does not exist yet.
    private static func canonical(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return (parent as NSString).appendingPathComponent(url.lastPathComponent)
    }

    // MARK: - Real file system

    public nonisolated static func posixOpen(_ path: String, _ flags: Int32) throws -> Int32 {
        let fd = Darwin.open(path, flags | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    /// The user's real home. Inside the sandbox `NSHomeDirectory()` and `~`
    /// both name the app's container, so a typed `~/Documents` would land in
    /// the container instead of where the user meant.
    public nonisolated static var userHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// The real Downloads folder. Inside the sandbox the system answers with
    /// the container's `Downloads` symlink; resolving it gives the path the
    /// user would type and recognise.
    public nonisolated static var userDownloadsDirectory: URL {
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? userHomeDirectory.appendingPathComponent("Downloads")
        return url.resolvingSymlinksInPath()
    }

    private static func isPermissionRefusal(_ error: Error) -> Bool {
        guard let posix = error as? POSIXError else { return false }
        return posix.code == .EPERM || posix.code == .EACCES
    }

    /// Said whenever the sandbox refuses a path, for input and destination
    /// alike: the fix is the same either way.
    public static var notPermittedMessage: String {
        localized(
            "libremac_sign_not_permitted",
            "LibreMac is not allowed to use that location. Typed paths work inside Downloads and the folders you have chosen; use Browse… for others.")
    }

    private static var writeFailedMessage: String {
        localized(
            "libremac_sign_write_failed",
            "The signed file could not be written to the chosen location.")
    }

    // MARK: - Phase → stage mapping

    private func applyPhase(_ phase: OperationPhase) {
        // Never resurrect a terminal (or reset) stage — `finished()` owns the
        // terminal transition and cancels the phase task, but a buffered phase
        // may still be in flight.
        switch stage {
        case .done, .failed, .idle:
            return
        case .preparing, .awaitingConsent, .working:
            break
        }
        switch phase {
        case .created, .connecting, .reading:
            stage = .preparing
        case .awaitingConsent, .authenticating:
            stage = .awaitingConsent
        case .signing, .timestamping:
            stage = .working
        case .done:
            break
        case .unknown:
            // Wire tolerance: a phase this build does not have a name for
            // yet (wire-frozen append-only `OperationPhase`) never
            // regresses the rendered stage — hold whatever stage is
            // already showing rather than guessing. This coordinator IS
            // the "current phase" consumer for the signing UI, so the
            // hold happens here (mirrors the C++ `AgentOperation`'s
            // held-phase policy; see `ClientCodec.h`'s tolerance table).
            break
        }
    }

    // MARK: - Artifact copy

    /// Copies the signed artifact fd into the already-open `output`, rewinding
    /// first — the agent may hand the fd back positioned at EOF — with a
    /// bounded read loop rather than slurping the whole file at once. The
    /// output is truncated first: it may be an existing file being replaced.
    private static func copyArtifact(from handle: FileHandle, to output: FileHandle) throws {
        _ = lseek(handle.fileDescriptor, 0, SEEK_SET)
        try output.truncate(atOffset: 0)
        let chunkSize = 64 * 1024
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    // MARK: - Error copy

    private static func message(for error: Error) -> String {
        guard let clientError = error as? AgentClientError else {
            return error.localizedDescription
        }
        switch clientError {
        case .serverError(let info):
            switch info.code {
            case .code(let code):
                return ErrorCopy.message(for: code, msgFallback: info.msgFallback ?? "")
            case .name:
                return ErrorCopy.message(
                    for: .communicationError, msgFallback: info.msgFallback ?? "")
            }
        case .timeout:
            return ErrorCopy.message(for: .watchdogTimeout, msgFallback: "")
        case .notSupported:
            // The agent lacks the feature token this call is gated on — a
            // capability gap, not a transport failure.
            return ErrorCopy.message(for: .capabilityMissing, msgFallback: "")
        case .notConnected, .connectionLost, .communicationError, .unexpectedReply:
            return ErrorCopy.message(for: .communicationError, msgFallback: "")
        }
    }

    private static func localized(_ key: String, _ fallback: String) -> String {
        AppLocalization.shared.loc(key, fallback)
    }
}

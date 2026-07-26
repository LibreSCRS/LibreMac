// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// `@Observable` view model that orchestrates a sign over the local agent. The
// PIN never reaches this process (protected authentication path): the
// coordinator only ever observes the operation's phases and renders a
// "confirm in the card dialog" affordance while it sits in awaiting-consent /
// authenticating. On success it copies the signed artifact — handed back as an
// fd over SCM_RIGHTS — to the user-chosen destination.

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
        /// Signed; payload is where the artifact was written.
        case done(destination: URL)
        /// Failed; payload is the resolved, user-facing message.
        case failed(message: String)
    }

    public private(set) var stage: Stage = .idle

    private let client: AgentSigningClient

    public init(client: AgentSigningClient) {
        self.client = client
    }

    /// Default per-sign options. A generic file sign defaults to a detached
    /// CAdES baseline signature; the TSA is owned by agent configuration, not a
    /// per-sign option (see `SignOptions`).
    public static let defaultOptions = SignOptions(
        format: "CAdES", level: "B-B", packaging: "detached")

    /// Returns the coordinator to `idle` so the UI can start another sign.
    public func reset() {
        if case .done = stage { stage = .idle }
        if case .failed = stage { stage = .idle }
    }

    /// Signs `inputURL` with `certId` on `card`, writing the signed artifact to
    /// `destinationURL`. A no-op if a sign is already in flight.
    public func sign(
        card: String,
        certId: String,
        inputURL: URL,
        destinationURL: URL,
        options: SignOptions = SigningCoordinator.defaultOptions
    ) async {
        switch stage {
        case .preparing, .awaitingConsent, .working:
            return
        case .idle, .done, .failed:
            break
        }

        stage = .preparing

        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: inputURL)
        } catch {
            stage = .failed(message: Self.localized(
                "libremac_sign_input_unreadable",
                "The selected file could not be opened for signing."))
            return
        }
        defer { try? input.close() }

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
        defer { try? artifact.close() }

        do {
            try Self.copyArtifact(from: artifact, to: destinationURL)
        } catch {
            stage = .failed(message: Self.localized(
                "libremac_sign_write_failed",
                "The signed file could not be written to the chosen location."))
            return
        }

        stage = .done(destination: destinationURL)
        Logger.signing.info(
            "Signed \(inputURL.lastPathComponent, privacy: .public) -> \(destinationURL.lastPathComponent, privacy: .public)")
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

    /// Copies the signed artifact fd to `url`, rewinding first — the agent may
    /// hand the fd back positioned at EOF — with a bounded read loop rather
    /// than slurping the whole file at once.
    private static func copyArtifact(from handle: FileHandle, to url: URL) throws {
        _ = lseek(handle.fileDescriptor, 0, SEEK_SET)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
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
        LocalizedText(key: key, defaultText: fallback).resolve()
    }
}

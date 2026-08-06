// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation

/// Drives an `AgentOperation` to completion with a client-side stall
/// watchdog, for callers that don't need to render per-phase progress
/// themselves (UI code that wants live phases drives `phases` +
/// `finished()` directly instead).
///
/// The watchdog is phase-aware: it is STOPPED while the operation
/// sits in `.awaitingConsent` or `.authenticating` (an operator can take
/// arbitrarily long to look at a prompt or touch a card) and re-armed the
/// moment the operation moves to any other ("machine") phase. If no phase
/// change is observed for `stallTimeout` seconds while the watchdog is
/// armed, the driver cancels the operation and returns a synthesized
/// `.watchdogTimeout` outcome without waiting for the server's own
/// `OpFinished` (which may never arrive if the agent itself is the one
/// that is stuck).
///
/// Wire-tolerance stateful layer: this is the Swift analog of the C++
/// `AgentOperation`'s held-phase / normalized-status policy
/// (`ClientCodec.h`'s tolerance table names it explicitly; the CDDL
/// `op-phase` comment does too). `Messages.swift` decodes an unrecognized
/// `OperationPhase`/`OperationStatus` through raw as `.unknown(UInt32)` —
/// deciding what that MEANS is this type's job, not the codec's:
///   - `StallWatch.recordPhase` never regresses its watchdog-exemption
///     check to an unrecognized phase — it holds the last KNOWN-good phase
///     (initially `.created`) for that computation, so an operator-facing
///     wait (`.awaitingConsent`/`.authenticating`) is never mistaken for a
///     "machine" phase merely because a newer agent reports it under a
///     name this build does not have yet.
///   - `driveToFinished` normalizes an unrecognized terminal
///     `OperationStatus` to `.error` before returning it (never surfacing
///     an unnamed status to the caller).
public struct OperationDriver: Sendable {

    /// Default stall timeout (mirrors the agent's own operation watchdog
    /// cadence) — override per call for tests or unusually slow cards.
    public static let opStallTimeout: TimeInterval = 35.0

    public init() {}

    /// Awaits `operation.finished()`, racing it against the stall
    /// watchdog described above. On a stall, calls `operation.cancel()`
    /// and returns `(.cancelled, .watchdogTimeout, nil, <message>)`
    /// immediately — it does not additionally wait for the server to
    /// confirm the cancellation.
    public func driveToFinished(
        _ operation: AgentOperation, stallTimeout: TimeInterval = OperationDriver.opStallTimeout
    ) async -> (OperationStatus, ErrorCode, String?, String) {
        let stallWatch = StallWatch()
        let phaseTask = Task {
            for await (phase, _) in operation.phases {
                await stallWatch.recordPhase(phase)
            }
        }

        let race = RaceBox<DriverOutcome>()
        let finishTask = Task {
            let outcome = await operation.finished()
            await race.resolve(.finished(outcome))
        }
        let watchdogTask = Task {
            let pollInterval = min(max(stallTimeout / 20, 0.01), 0.5)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if Task.isCancelled { return }
                if await stallWatch.isStalled(timeout: stallTimeout) {
                    await race.resolve(.stalled)
                    return
                }
            }
        }

        let outcome = await race.wait()
        phaseTask.cancel()
        finishTask.cancel()
        watchdogTask.cancel()

        switch outcome {
        case .finished(let value):
            return Self.normalizeTerminal(value)
        case .stalled:
            await operation.cancel()
            return (.cancelled, .watchdogTimeout, nil, "operation stalled: no phase progress for \(Int(stallTimeout))s")
        }
    }

    /// Wire tolerance: an `OperationStatus` this build does not have a name
    /// for yet (a future agent's terminal outcome, wire-frozen append-only)
    /// is normalized to `.error` here, once, before the terminal value is
    /// returned to the caller — mirroring the C++ `AgentOperation`'s
    /// `finalizeTerminal` (see the type doc comment). `code` /
    /// `msgKey`/`msgFallback` pass through unchanged either way — only the
    /// status itself is normalized.
    private static func normalizeTerminal(
        _ value: (OperationStatus, ErrorCode, String?, String)
    ) -> (OperationStatus, ErrorCode, String?, String) {
        guard value.0.isKnown else {
            return (.error, value.1, value.2, value.3)
        }
        return value
    }
}

private enum DriverOutcome: Sendable {
    case finished((OperationStatus, ErrorCode, String?, String))
    case stalled
}

/// Tracks "time since the last phase change" plus whether the watchdog is
/// currently exempt (an operator-facing phase). An actor rather than a
/// lock: `recordPhase`/`isStalled` are called from independent tasks and
/// neither is hot enough to need anything faster.
private actor StallWatch {
    /// Monotonic (`ContinuousClock`) — a wall-clock (`Date`) measurement
    /// here would let an NTP step or manual clock change spuriously fire
    /// (or suppress) the watchdog that cancels a live operation.
    private var lastChangeAt = ContinuousClock.now
    private var exempt = false
    /// The last KNOWN-good phase seen (`.created` initially, mirroring the
    /// C++ `AgentOperation`'s initial `Created`). Wire tolerance: an
    /// unrecognized phase never updates this — see `recordPhase`.
    private var heldPhase: OperationPhase = .created

    func recordPhase(_ phase: OperationPhase) {
        // Progress is still "live" even when the phase itself is one this
        // build does not have a name for yet, so the stall clock always
        // resets here.
        lastChangeAt = ContinuousClock.now
        // Wire tolerance: never regress the exemption check to an
        // unrecognized phase — hold the last known-good one instead (see
        // the type doc comment and `OperationDriver`'s tolerance note).
        if phase.isKnown {
            heldPhase = phase
        }
        exempt = heldPhase == .awaitingConsent || heldPhase == .authenticating
    }

    func isStalled(timeout: TimeInterval) -> Bool {
        guard !exempt else { return false }
        return ContinuousClock.now - lastChangeAt >= .seconds(timeout)
    }
}

/// Resolves once with whichever of several concurrently racing producers
/// calls `resolve(_:)` first; every later call and every waiter that
/// arrives after resolution see that same first value.
private actor RaceBox<T: Sendable> {
    private var value: T?
    private var waiters: [CheckedContinuation<T, Never>] = []

    func resolve(_ newValue: T) {
        guard value == nil else { return }
        value = newValue
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: newValue)
        }
    }

    func wait() async -> T {
        if let value { return value }
        return await withCheckedContinuation { continuation in
            if let value {
                continuation.resume(returning: value)
            } else {
                waiters.append(continuation)
            }
        }
    }
}

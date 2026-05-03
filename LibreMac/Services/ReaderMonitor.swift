// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Bridges Apple's KVO-driven `TKSmartCardSlotManager` reader API onto a
// Swift-native `AsyncStream<CardEvent>`. One process-wide instance lives
// in `CardMonitor`; the menu-bar UI subscribes to the stream and re-renders
// on each event.
//
// Design citations:
// - Stroustrup *A Tour of C++* §17 — prefer the highest-level abstraction
//   that does not sacrifice correctness; an `AsyncStream` is the Swift
//   idiom that matches `for await ... in events` cleanly.
// - Meyers *Effective Modern C++* Item 21 — express ownership in the type
//   system. ReaderMonitor owns the `NSKeyValueObservation` tokens and
//   invalidates them in `deinit`.

import CryptoTokenKit
import Foundation
import LibreMacShared
import os

/// High-level reader / card lifecycle event consumed by `CardMonitor`.
///
/// Sendable because every payload type is a value type (`String`, `Data`)
/// and therefore safe to hand from the KVO callback queue across to the
/// MainActor-bound consumer.
public enum CardEvent: Sendable, Equatable {
    case readerConnected(name: String)
    case readerDisconnected(name: String)
    case cardInserted(reader: String, atr: Data)
    case cardRemoved(reader: String)
}

/// Wraps `TKSmartCardSlotManager`'s KVO observations of `slotNames` + per-slot
/// `state` into an `AsyncStream<CardEvent>`. One instance per process; the
/// stream finishes only on `deinit`.
///
/// Marked `@unchecked Sendable` because the KVO callbacks fire on an internal
/// CTK queue. All mutable state (`slotObservations`, the
/// `AsyncStream.Continuation`) is touched only from those callbacks; the
/// continuation type is itself `Sendable` and serialises into the consumer
/// task.
public final class ReaderMonitor: @unchecked Sendable {
    /// Apple documents `TKSmartCardSlotManager.default` as nilable when the
    /// process lacks the smartcard entitlement; we keep the optional and
    /// log if it is missing rather than fatalError'ing — the menu-bar UI
    /// still has to render in that degraded mode.
    private let manager: TKSmartCardSlotManager? = TKSmartCardSlotManager.default

    /// Per-slot KVO tokens; keyed by reader name. Invalidated in `deinit`.
    private var slotObservations: [String: NSKeyValueObservation] = [:]
    /// Top-level KVO token observing `slotNames`. Invalidated in `deinit`.
    private var slotsObservation: NSKeyValueObservation?
    /// Yields events into `events`; finished in `deinit` so subscribers'
    /// `for await` loops terminate cleanly.
    private let continuation: AsyncStream<CardEvent>.Continuation
    /// Public stream the consumer iterates.
    public let events: AsyncStream<CardEvent>

    public init() {
        var cont: AsyncStream<CardEvent>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.continuation = cont

        guard let manager else {
            Logger.card.error(
                "TKSmartCardSlotManager.default is nil — does this binary have the smartcard entitlement?"
            )
            return
        }

        slotsObservation = manager.observe(\.slotNames, options: [.initial, .new]) {
            [weak self] _, change in
            self?.handleSlotNamesChange(change.newValue ?? [])
        }
    }

    deinit {
        slotsObservation?.invalidate()
        for obs in slotObservations.values { obs.invalidate() }
        continuation.finish()
    }

    private func handleSlotNamesChange(_ names: [String]) {
        let known = Set(slotObservations.keys)
        let current = Set(names)

        for added in current.subtracting(known) {
            continuation.yield(.readerConnected(name: added))
            attachSlotObserver(added)
        }
        for removed in known.subtracting(current) {
            slotObservations[removed]?.invalidate()
            slotObservations.removeValue(forKey: removed)
            continuation.yield(.readerDisconnected(name: removed))
        }
    }

    private func attachSlotObserver(_ name: String) {
        guard let manager else { return }
        manager.getSlot(withName: name) { [weak self] slot in
            guard let self, let slot else { return }
            let obs = slot.observe(\.state, options: [.initial, .new]) {
                [weak self] s, _ in
                self?.handleSlotStateChange(reader: name, slot: s)
            }
            self.slotObservations[name] = obs
        }
    }

    private func handleSlotStateChange(reader: String, slot: TKSmartCardSlot) {
        switch slot.state {
        case .validCard:
            let atr = slot.atr?.bytes ?? Data()
            continuation.yield(.cardInserted(reader: reader, atr: atr))
        case .empty, .probing, .muteCard:
            continuation.yield(.cardRemoved(reader: reader))
        case .missing:
            // Slot is going away; the slotNames KVO will fire next with
            // the removal event. Log here so field diagnostics can correlate
            // a missing-state observation with a subsequent
            // readerDisconnected event.
            Logger.card.debug("Slot \(reader, privacy: .public) reports .missing")
        @unknown default:
            Logger.card.warning(
                "Unknown TKSmartCardSlot state \(slot.state.rawValue, privacy: .public)")
        }
    }
}

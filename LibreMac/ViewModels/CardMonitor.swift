// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// `@Observable` view model that drives the menu-bar UI. Owns the
// `ReaderMonitor` and the active `BridgeSession`; all mutable state mutates
// on the MainActor so SwiftUI re-renders happen on the same actor that
// produced the change.
//
// Design citations:
// - Stroustrup *A Tour of C++* §15 — keep the cross-language boundary thin.
//   `BridgeSession` is the only place that touches the C ABI; this view
//   model speaks Swift idioms only.
// - Meyers *Effective Modern C++* Item 39 — `Task` is the Swift idiom for
//   "process events from a stream while this object lives"; the Task is
//   cancelled in `deinit` to terminate the consumer cleanly.

import Foundation
import LibreMacShared
import Observation
import os

@Observable
@MainActor
public final class CardMonitor {
    /// High-level state shown in the menu-bar UI. Equatable so SwiftUI can
    /// short-circuit re-renders, and so the menu-bar icon binding is cheap.
    public enum Status: Sendable, Equatable {
        case noReader
        case readerConnected
        case cardPresent(atr: String)
        case readingCertificates
        case ready(certificateCount: Int)
        case error(LibreMacError)
    }

    public private(set) var status: Status = .noReader
    public private(set) var connectedReaders: [String] = []
    public private(set) var activeReader: String?
    public private(set) var certificates: [Data] = []

    private let registry: BridgeRegistry
    private let monitor = ReaderMonitor()
    private var session: BridgeSession?

    /// Non-isolated holder so `deinit` can cancel the consumer task without
    /// crossing actor boundaries (Swift 6 strict concurrency forbids
    /// synchronous access to actor-isolated state from a `deinit`). The
    /// holder is `final` and only stores a `Sendable` `Task<Void, Never>`,
    /// so the cancellation is safe from any thread.
    private final class TaskHolder: @unchecked Sendable {
        var task: Task<Void, Never>?
        init() {}
    }
    private let taskHolder = TaskHolder()

    public init(registry: BridgeRegistry) {
        self.registry = registry
        // Capture the Sendable AsyncStream into a local before the Task
        // closure to avoid pulling `self` (MainActor-isolated) into the
        // detached executor's iteration.
        let events = monitor.events
        taskHolder.task = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    deinit {
        taskHolder.task?.cancel()
    }

    private func handle(_ event: CardEvent) async {
        switch event {
        case .readerConnected(let name):
            if !connectedReaders.contains(name) { connectedReaders.append(name) }
            if status == .noReader { status = .readerConnected }

        case .readerDisconnected(let name):
            connectedReaders.removeAll(where: { $0 == name })
            if activeReader == name {
                session = nil
                certificates = []
                status = connectedReaders.isEmpty ? .noReader : .readerConnected
            }

        case .cardInserted(let reader, let atr):
            activeReader = reader
            status = .cardPresent(
                atr: atr.map { String(format: "%02X", $0) }.joined(separator: " "))
            await openSessionAndReadCerts(reader: reader)

        case .cardRemoved(let reader):
            if activeReader == reader {
                session = nil
                certificates = []
                status = .readerConnected
                activeReader = nil
            }
        }
    }

    private func openSessionAndReadCerts(reader: String) async {
        status = .readingCertificates
        do throws(LibreMacError) {
            let s = try BridgeSession(registry: registry, reader: reader)
            let certs = try s.readCertificates()
            session = s
            certificates = certs
            status = .ready(certificateCount: certs.count)
            Logger.card.info(
                "Read \(certs.count, privacy: .public) certs from \(reader, privacy: .public)")
        } catch {
            status = .error(error)
            Logger.card.error(
                "Open/read failed for \(reader, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Expose the active session for downstream signing flows.
    public var activeSession: BridgeSession? { session }
}

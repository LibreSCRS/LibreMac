// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Synchronization

/// The stream-consumer tasks a `@MainActor` object starts in its `init` and
/// cancels in its `deinit`. Swift 6 forbids a `deinit` synchronous access to
/// main-actor state, so the tasks live here, behind a lock of their own, where
/// the nonisolated `deinit` reaches them.
public final class TaskHolder: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    public init() {}

    public func add(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    /// Cancels every task added so far and forgets them.
    public func cancelAll() {
        let pending = tasks.withLock { tasks in
            let all = tasks
            tasks.removeAll()
            return all
        }
        for task in pending {
            task.cancel()
        }
    }
}

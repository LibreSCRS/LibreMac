// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Testing
@testable import LibreMacShared

@Suite("TaskHolder")
struct TaskHolderTests {
    @Test("cancelAll cancels every task added, once")
    func cancelAllCancelsEveryTask() async {
        let holder = TaskHolder()
        let first = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
        let second = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
        holder.add(first)
        holder.add(second)

        holder.cancelAll()
        await first.value
        await second.value
        #expect(first.isCancelled)
        #expect(second.isCancelled)

        // A task added after cancelAll is not cancelled by the earlier call.
        let later = Task<Void, Never> {}
        holder.add(later)
        #expect(!later.isCancelled)
        later.cancel()
    }
}

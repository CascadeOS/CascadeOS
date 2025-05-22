// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A simple spinlock implementation using tickets to ensure fairness.
const TicketSpinLock = @This();

current: std.atomic.Value(u32) = .init(0),
ticket: std.atomic.Value(u32) = .init(0),
holding_executor: kernel.Executor.Id = .none,

/// Locks the spinlock.
pub fn lock(self: *TicketSpinLock, current_task: *kernel.Task) void {
    current_task.incrementInterruptDisable();

    const executor = current_task.state.running;
    std.debug.assert(!self.isLockedByCurrent(current_task)); // recursive locks are not supported

    const ticket = self.ticket.fetchAdd(1, .monotonic);
    if (self.current.load(.acquire) != ticket) {
        @branchHint(.unlikely);

        while (true) {
            kernel.arch.spinLoopHint();
            if (self.current.load(.monotonic) == ticket) break;
        }

        _ = self.current.load(.acquire);
    }

    self.holding_executor = executor.id;
    current_task.spinlocks_held += 1;
}

/// Unlock the spinlock.
///
/// Asserts that the current executor is the one that locked the spinlock.
pub fn unlock(self: *TicketSpinLock, current_task: *kernel.Task) void {
    std.debug.assert(current_task.spinlocks_held != 0);
    std.debug.assert(self.isLockedByCurrent(current_task));

    self.unsafeUnlock();

    current_task.spinlocks_held -= 1;
    current_task.decrementInterruptDisable();
}

/// Unlock the spinlock.
///
/// Performs no checks and is unsafe, prefer `unlock` instead.
pub inline fn unsafeUnlock(self: *TicketSpinLock) void {
    self.holding_executor = .none;
    self.current.store(self.current.raw +% 1, .release);
}

/// Poison the spinlock, this will cause any future attempts to lock the spinlock to deadlock.
pub fn poison(self: *TicketSpinLock) void {
    _ = self.current.fetchSub(1, .release);
}

/// Returns true if the spinlock is locked by the current executor.
pub fn isLockedByCurrent(self: *const TicketSpinLock, current_task: *const kernel.Task) bool {
    return self.holding_executor == current_task.state.running.id;
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

//! A simple spinlock implementation using tickets to ensure fairness.
const TicketSpinLock = @This();

current: std.atomic.Value(u32) = .init(0),
ticket: std.atomic.Value(u32) = .init(0),
holding_executor: std.atomic.Value(kernel.Executor.Id) = .init(.none),
poisoned: std.atomic.Value(bool) = .init(false),

/// Locks the spinlock.
pub fn lock(self: *TicketSpinLock, current_task: *kernel.Task) void {
    self.lockImpl(current_task, false) catch comptime unreachable;
}

/// Locks the spinlock.
///
/// If the spinlock is poisoned, returns an `error.Poisoned`.
pub fn lockWithPoisonCheck(self: *TicketSpinLock, current_task: *kernel.Task) error{Poisoned}!void {
    try self.lockImpl(current_task, true);
}

fn lockImpl(self: *TicketSpinLock, current_task: *kernel.Task, comptime poison_check: bool) !void {
    current_task.incrementInterruptDisable();

    const executor = current_task.state.running;
    std.debug.assert(!self.isLockedBy(executor.id)); // recursive locks are not supported

    if (comptime poison_check) {
        if (self.poisoned.load(.acquire)) return error.Poisoned;
    }

    const ticket = self.ticket.fetchAdd(1, .acq_rel);
    while (self.current.load(.monotonic) != ticket) {
        if (comptime poison_check) {
            if (self.poisoned.load(.monotonic)) return error.Poisoned;
        }

        kernel.arch.spinLoopHint();
    }
    self.holding_executor.store(executor.id, .release);

    current_task.spinlocks_held += 1;
}

/// Unlock the spinlock.
///
/// Asserts that the current executor is the one that locked the spinlock.
pub fn unlock(self: *TicketSpinLock, current_task: *kernel.Task) void {
    std.debug.assert(current_task.spinlocks_held != 0);

    const executor = current_task.state.running;
    std.debug.assert(self.holding_executor.load(.acquire) == executor.id);

    self.unsafeUnlock();

    current_task.spinlocks_held -= 1;

    current_task.decrementInterruptDisable();
}

/// Unlock the spinlock.
///
/// Performs no checks and is unsafe, prefer `unlock` instead.
pub fn unsafeUnlock(self: *TicketSpinLock) void {
    self.holding_executor.store(.none, .release);
    _ = self.current.fetchAdd(1, .acq_rel);
}

/// Poison the spinlock, this will cause any future attempts to lock the spinlock to deadlock.
pub fn poison(self: *TicketSpinLock) void {
    _ = self.current.fetchSub(1, .acq_rel);
    self.poisoned.store(true, .release);
}

/// Returns true if the spinlock is locked by the given executor.
pub fn isLockedBy(self: *const TicketSpinLock, executor_id: kernel.Executor.Id) bool {
    return self.holding_executor.load(.acquire) == executor_id;
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

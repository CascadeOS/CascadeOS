// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! A simple spinlock implementation using tickets to ensure fairness.
const TicketSpinLock = @This();

current: u32 = 0,
ticket: u32 = 0,
current_holder: kernel.Executor.Id = .none,

/// Locks the spinlock.
///
/// Asserts that interrupts are disabled.
pub fn lock(self: *TicketSpinLock, context: *kernel.Context) void {
    std.debug.assert(context.interrupt_disable_count > 0);
    const executor = context.executor.?;

    std.debug.assert(!self.isLockedBy(executor.id));

    const ticket = @atomicRmw(u32, &self.ticket, .Add, 1, .acq_rel);
    while (@atomicLoad(u32, &self.current, .monotonic) != ticket) {
        arch.spinLoopHint();
    }
    @atomicStore(kernel.Executor.Id, &self.current_holder, executor.id, .release);
}

/// Unlock the spinlock.
///
/// Asserts that interrupts are disabled and that the current executor is the one that locked the spinlock.
pub fn unlock(self: *TicketSpinLock, context: *kernel.Context) void {
    std.debug.assert(context.interrupt_disable_count > 0);
    std.debug.assert(self.current_holder == context.executor.?.id);

    self.unsafeUnlock();
}

/// Unlock the spinlock.
///
/// Performs no checks and is unsafe, prefer `unlock` instead.
pub fn unsafeUnlock(self: *TicketSpinLock) void {
    @atomicStore(kernel.Executor.Id, &self.current_holder, .none, .release);
    _ = @atomicRmw(u32, &self.current, .Add, 1, .acq_rel);
}

/// Poison the spinlock, this will cause any future attempts to lock the spinlock to deadlock.
pub fn poison(self: *TicketSpinLock) void {
    _ = @atomicRmw(u32, &self.current, .Sub, 1, .acq_rel);
}

/// Returns true if the spinlock is locked by the given executor.
pub fn isLockedBy(self: *const TicketSpinLock, executor_id: kernel.Executor.Id) bool {
    return @atomicLoad(kernel.Executor.Id, &self.current_holder, .acquire) == executor_id;
}

const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const std = @import("std");

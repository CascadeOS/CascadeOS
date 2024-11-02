// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! A simple spinlock implementation using tickets to ensure fairness.
//!
//! **WARNING**: This lock is not interrupt safe, it is the callers responsibility to ensure that interrupts are
/// disabled while the lock is held.
const TicketSpinLock = @This();

current: u32 = 0,
ticket: u32 = 0,
current_holder: kernel.Executor.Id = .none,

/// Lock the spinlock.
///
/// **WARNING**: This lock is not interrupt safe, it is the callers responsibility to ensure that interrupts are
/// disabled while the lock is held.
pub fn lock(self: *TicketSpinLock) void {
    const current_executor = arch.getCurrentExecutor();

    std.debug.assert(!arch.interrupts.areEnabled());
    std.debug.assert(current_executor.interrupt_disable_count != 0);

    std.debug.assert(!self.isLockedBy(current_executor.id));

    const ticket = @atomicRmw(u32, &self.ticket, .Add, 1, .acq_rel);
    while (@atomicLoad(u32, &self.current, .monotonic) != ticket) {
        arch.spinLoopHint();
    }
    @atomicStore(kernel.Executor.Id, &self.current_holder, current_executor.id, .release);
}

pub fn unlock(self: *TicketSpinLock) void {
    const current_executor = arch.getCurrentExecutor();

    std.debug.assert(!arch.interrupts.areEnabled());
    std.debug.assert(current_executor.interrupt_disable_count != 0);

    std.debug.assert(self.isLockedBy(current_executor.id));

    @atomicStore(kernel.Executor.Id, &self.current_holder, .none, .release);
    _ = @atomicRmw(u32, &self.current, .Add, 1, .acq_rel);
}

/// Poison the spinlock, this will cause any future attempts to lock the spinlock to deadlock.
pub fn poison(self: *TicketSpinLock) void {
    _ = @atomicRmw(u32, &self.current, .Sub, 1, .acq_rel);
}

/// Returns true if the spinlock is locked by the current executor.
fn isLockedBy(self: *const TicketSpinLock, executor_id: kernel.Executor.Id) bool {
    return @atomicLoad(kernel.Executor.Id, &self.current_holder, .acquire) == executor_id;
}

const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const std = @import("std");

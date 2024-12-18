// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! A simple spinlock implementation using tickets to ensure fairness.
const TicketSpinLock = @This();

current: u32 = 0,
ticket: u32 = 0,
current_holder: kernel.Executor.Id = .none,

pub const Held = struct {
    context: *kernel.Context,
    spinlock: *TicketSpinLock,

    /// Unlocks the spinlock.
    ///
    /// Enables interrupts if they were previously enabled.
    pub fn unlock(self: Held) void {
        self.spinlock.unsafeRelease();
        self.context.decrementInterruptDisable();
    }
};

/// Locks the spinlock.
///
/// Disables interrupts if they are currently enabled.
pub fn lock(self: *TicketSpinLock, context: *kernel.Context) Held {
    context.incrementInterruptDisable();
    const executor = context.executor.?;

    std.debug.assert(!self.isLockedBy(executor.id));

    const ticket = @atomicRmw(u32, &self.ticket, .Add, 1, .acq_rel);
    while (@atomicLoad(u32, &self.current, .monotonic) != ticket) {
        arch.spinLoopHint();
    }
    @atomicStore(kernel.Executor.Id, &self.current_holder, executor.id, .release);

    return .{
        .context = context,
        .spinlock = self,
    };
}

/// Poison the spinlock, this will cause any future attempts to lock the spinlock to deadlock.
pub fn poison(self: *TicketSpinLock) void {
    _ = @atomicRmw(u32, &self.current, .Sub, 1, .acq_rel);
}

/// Releases the spinlock.
///
/// Intended to be used only when the caller needs to unlock the spinlock on behalf of another task.
pub fn unsafeRelease(self: *TicketSpinLock) void {
    @atomicStore(kernel.Executor.Id, &self.current_holder, .none, .release);
    _ = @atomicRmw(u32, &self.current, .Add, 1, .acq_rel);
}

/// Returns true if the spinlock is locked by the given executor.
pub fn isLockedBy(self: *const TicketSpinLock, executor_id: kernel.Executor.Id) bool {
    return @atomicLoad(kernel.Executor.Id, &self.current_holder, .acquire) == executor_id;
}

const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const std = @import("std");

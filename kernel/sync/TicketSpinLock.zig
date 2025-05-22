// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A fair in order spinlock.
//!
//! Interrupts are disabled while locked.

const TicketSpinLock = @This();

containter: Container = .{ .full = 0 },
holding_executor: kernel.Executor.Id = .none,

const Container = extern union {
    contents: extern struct {
        current: u32 = 0,
        ticket: u32 = 0,
    },
    full: u64,

    comptime {
        std.debug.assert(@sizeOf(Container) == @sizeOf(u64));
    }
};

/// Locks the spinlock.
pub fn lock(self: *TicketSpinLock, current_task: *kernel.Task) void {
    std.debug.assert(!self.isLockedByCurrent(current_task)); // recursive locks are not supported

    current_task.incrementInterruptDisable();

    const ticket = @atomicRmw(u32, &self.containter.contents.ticket, .Add, 1, .monotonic);

    if (@atomicLoad(u32, &self.containter.contents.current, .acquire) != ticket) {
        @branchHint(.unlikely);

        while (true) {
            kernel.arch.spinLoopHint();
            if (@atomicLoad(u32, &self.containter.contents.current, .monotonic) == ticket) break;
        }

        _ = @atomicLoad(u32, &self.containter.contents.current, .acquire);
    }

    self.holding_executor = current_task.state.running.id;
    current_task.spinlocks_held += 1;
}

/// Try to lock the spinlock.
pub fn tryLock(self: *TicketSpinLock, current_task: *kernel.Task) bool {
    std.debug.assert(!self.isLockedByCurrent(current_task)); // recursive locks are not supported

    current_task.incrementInterruptDisable();

    const old_container = @atomicLoad(Container, &self.containter, .monotonic);

    if (old_container.contents.current != old_container.contents.ticket) {
        @branchHint(.unlikely);

        current_task.decrementInterruptDisable();
        return false;
    }

    var new_container = old_container;
    new_container.contents.ticket +%= 1;

    if (@cmpxchgStrong(Container, &self.containter, old_container, new_container, .acquire, .monotonic)) |_| {
        @branchHint(.unlikely);

        current_task.decrementInterruptDisable();
        return false;
    }

    self.holding_executor = current_task.state.running.id;
    current_task.spinlocks_held += 1;

    return true;
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
    @atomicStore(u32, &self.containter.contents.current, self.containter.contents.current +% 1, .release);
}

/// Poison the spinlock, this will cause any future attempts to lock the spinlock to deadlock.
pub fn poison(self: *TicketSpinLock) void {
    _ = @atomicRmw(u32, &self.containter.contents.current, .Sub, 1, .release);
}

/// Returns true if the spinlock is locked by the current executor.
pub fn isLockedByCurrent(self: *const TicketSpinLock, current_task: *const kernel.Task) bool {
    return self.holding_executor == current_task.state.running.id;
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

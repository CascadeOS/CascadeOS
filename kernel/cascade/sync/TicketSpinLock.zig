// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A fair in order spinlock.
//!
//! Interrupts are disabled while locked.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const TicketSpinLock = @This();

container: Container = .{ .full = 0 },
holding_executor: ?*const cascade.Executor = null,

/// Locks the spinlock.
pub fn lock(ticket_spin_lock: *TicketSpinLock) void {
    const current_task: Task.Current = .get();

    current_task.incrementInterruptDisable();

    if (core.is_debug) std.debug.assert(!ticket_spin_lock.isLockedByCurrent()); // recursive locks are not supported

    const ticket = @atomicRmw(u32, &ticket_spin_lock.container.contents.ticket, .Add, 1, .monotonic);

    if (@atomicLoad(u32, &ticket_spin_lock.container.contents.current, .acquire) != ticket) {
        while (true) {
            arch.spinLoopHint();
            if (@atomicLoad(u32, &ticket_spin_lock.container.contents.current, .monotonic) == ticket) break;
        }

        _ = @atomicLoad(u32, &ticket_spin_lock.container.contents.current, .acquire);
    }

    ticket_spin_lock.holding_executor = current_task.knownExecutor();
    current_task.task.spinlocks_held += 1;
}

/// Try to lock the spinlock.
pub fn tryLock(ticket_spin_lock: *TicketSpinLock) bool {
    // no need to check if we already have the lock as the below logic will not allow us
    // to acquire it again

    const current_task: Task.Current = .get();

    current_task.incrementInterruptDisable();

    const old_container: Container = @bitCast(@atomicLoad(u64, &ticket_spin_lock.container.full, .monotonic));

    if (old_container.contents.current != old_container.contents.ticket) {
        current_task.decrementInterruptDisable();
        return false;
    }

    var new_container = old_container;
    new_container.contents.ticket +%= 1;

    if (@cmpxchgStrong(
        u64,
        &ticket_spin_lock.container.full,
        old_container.full,
        new_container.full,
        .acquire,
        .monotonic,
    )) |_| {
        @branchHint(.unlikely);

        current_task.decrementInterruptDisable();
        return false;
    }

    ticket_spin_lock.holding_executor = current_task.knownExecutor();
    current_task.task.spinlocks_held += 1;

    return true;
}

/// Unlock the spinlock.
///
/// Asserts that the current executor is the one that locked the spinlock.
pub fn unlock(ticket_spin_lock: *TicketSpinLock) void {
    const current_task: Task.Current = .get();

    if (core.is_debug) {
        std.debug.assert(current_task.task.spinlocks_held != 0);
        std.debug.assert(ticket_spin_lock.isLockedByCurrent());
    }

    ticket_spin_lock.unsafeUnlock();

    current_task.task.spinlocks_held -= 1;
    current_task.decrementInterruptDisable();
}

/// Unlocks the spinlock, without decrementing interrupt disable count or spinlock held count.
///
/// Performs no checks, prefer `unlock` instead.
pub inline fn unsafeUnlock(ticket_spin_lock: *TicketSpinLock) void {
    ticket_spin_lock.holding_executor = null;
    _ = @atomicRmw(u32, &ticket_spin_lock.container.contents.current, .Add, 1, .release);
}

/// Poison the spinlock, this will cause any future attempts to lock the spinlock to deadlock.
pub fn poison(ticket_spin_lock: *TicketSpinLock) void {
    _ = @atomicRmw(u32, &ticket_spin_lock.container.contents.current, .Sub, 1, .release);
}

/// Returns true if the spinlock is locked by the current executor.
pub fn isLockedByCurrent(ticket_spin_lock: *const TicketSpinLock) bool {
    const executor = Task.Current.get().task.known_executor orelse return false;
    return ticket_spin_lock.holding_executor == executor;
}

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

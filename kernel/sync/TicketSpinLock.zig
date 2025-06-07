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
pub fn lock(ticket_spin_lock: *TicketSpinLock, current_task: *kernel.Task) void {
    std.debug.assert(!ticket_spin_lock.isLockedByCurrent(current_task)); // recursive locks are not supported

    current_task.incrementInterruptDisable();

    const ticket = @atomicRmw(u32, &ticket_spin_lock.containter.contents.ticket, .Add, 1, .monotonic);

    if (@atomicLoad(u32, &ticket_spin_lock.containter.contents.current, .acquire) != ticket) {
        @branchHint(.unlikely);

        while (true) {
            kernel.arch.spinLoopHint();
            if (@atomicLoad(u32, &ticket_spin_lock.containter.contents.current, .monotonic) == ticket) break;
        }

        _ = @atomicLoad(u32, &ticket_spin_lock.containter.contents.current, .acquire);
    }

    ticket_spin_lock.holding_executor = current_task.state.running.id;
    current_task.spinlocks_held += 1;
}

/// Try to lock the spinlock.
pub fn tryLock(ticket_spin_lock: *TicketSpinLock, current_task: *kernel.Task) bool {
    // no need to check if we already have the lock as the below logic will not allow us
    // to acquire it again

    current_task.incrementInterruptDisable();

    const old_container = @atomicLoad(Container, &ticket_spin_lock.containter, .monotonic);

    if (old_container.contents.current != old_container.contents.ticket) {
        @branchHint(.unlikely);

        current_task.decrementInterruptDisable();
        return false;
    }

    var new_container = old_container;
    new_container.contents.ticket +%= 1;

    if (@cmpxchgStrong(Container, &ticket_spin_lock.containter, old_container, new_container, .acquire, .monotonic)) |_| {
        @branchHint(.unlikely);

        current_task.decrementInterruptDisable();
        return false;
    }

    ticket_spin_lock.holding_executor = current_task.state.running.id;
    current_task.spinlocks_held += 1;

    return true;
}

/// Unlock the spinlock.
///
/// Asserts that the current executor is the one that locked the spinlock.
pub fn unlock(ticket_spin_lock: *TicketSpinLock, current_task: *kernel.Task) void {
    std.debug.assert(current_task.spinlocks_held != 0);
    std.debug.assert(ticket_spin_lock.isLockedByCurrent(current_task));

    ticket_spin_lock.unsafeUnlock();

    current_task.spinlocks_held -= 1;
    current_task.decrementInterruptDisable();
}

/// Unlock the spinlock.
///
/// Performs no checks and is unsafe, prefer `unlock` instead.
pub inline fn unsafeUnlock(ticket_spin_lock: *TicketSpinLock) void {
    ticket_spin_lock.holding_executor = .none;
    @atomicStore(u32, &ticket_spin_lock.containter.contents.current, ticket_spin_lock.containter.contents.current +% 1, .release);
}

/// Poison the spinlock, this will cause any future attempts to lock the spinlock to deadlock.
pub fn poison(ticket_spin_lock: *TicketSpinLock) void {
    _ = @atomicRmw(u32, &ticket_spin_lock.containter.contents.current, .Sub, 1, .release);
}

/// Returns true if the spinlock is locked by the current executor.
pub fn isLockedByCurrent(ticket_spin_lock: *const TicketSpinLock, current_task: *const kernel.Task) bool {
    return ticket_spin_lock.holding_executor == current_task.state.running.id;
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

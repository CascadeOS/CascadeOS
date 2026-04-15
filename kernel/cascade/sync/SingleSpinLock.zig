// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: CascadeOS Contributors

//! A spinlock optimized for non-contended use cases e.g. protecting per-executor data that is rarely accessed by other executors.
//!
//! Recursive locks are not supported.
//!
//! Interrupts are disabled while locked.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const SingleSpinLock = @This();

holding_executor: std.atomic.Value(?*const cascade.Executor) align(std.atomic.cache_line) = .init(null),

pub fn lock(single_spin_lock: *SingleSpinLock) void {
    const current_task: cascade.Task.Current = .get();
    current_task.incrementInterruptDisable();

    defer current_task.task.spinlocks_held += 1;

    const current_executor = current_task.knownExecutor();

    const locked_by = single_spin_lock.holding_executor.cmpxchgStrong(
        null,
        current_executor,
        .acquire,
        .monotonic,
    ) orelse {
        @branchHint(.likely);
        return;
    };

    if (locked_by == current_executor) {
        @branchHint(.cold);
        @panic("recursive lock");
    }

    while (single_spin_lock.holding_executor.cmpxchgWeak(
        null,
        current_executor,
        .acquire,
        .monotonic,
    )) |_| {
        arch.spinLoopHint();
    }
}

pub fn tryLock(single_spin_lock: *SingleSpinLock) bool {
    const current_task: cascade.Task.Current = .get();
    current_task.incrementInterruptDisable();
    const current_executor = current_task.knownExecutor();

    if (single_spin_lock.holding_executor.cmpxchgStrong(
        null,
        current_executor,
        .acquire,
        .monotonic,
    )) |locked_by| {
        @branchHint(.unlikely);

        if (locked_by == current_executor) {
            @branchHint(.cold);
            @panic("recursive lock");
        }

        current_task.decrementInterruptDisable();
        return false;
    }

    current_task.task.spinlocks_held += 1;
    return true;
}

pub fn unlock(single_spin_lock: *SingleSpinLock) void {
    const current_task: cascade.Task.Current = .get();

    if (core.is_debug) {
        std.debug.assert(current_task.task.spinlocks_held != 0);
        std.debug.assert(single_spin_lock.isLockedByCurrent());
    }

    single_spin_lock.unsafeUnlock();

    current_task.task.spinlocks_held -= 1;
    current_task.decrementInterruptDisable();
}

/// Unlocks the spinlock, without decrementing interrupt disable count or spinlock held count.
///
/// Performs no checks, prefer `unlock` instead.
pub inline fn unsafeUnlock(single_spin_lock: *SingleSpinLock) void {
    single_spin_lock.holding_executor.store(null, .release);
}

/// Returns true if the spinlock is locked by the current executor.
pub fn isLockedByCurrent(single_spin_lock: *const SingleSpinLock) bool {
    const executor = cascade.Task.Current.get().task.known_executor orelse return false;
    return single_spin_lock.holding_executor.load(.monotonic) == executor;
}

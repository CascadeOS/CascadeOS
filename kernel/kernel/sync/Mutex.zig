// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A fair in order mutex.
//!
//! Preemption is disabled while locked.

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const Mutex = @This();

locked_by: std.atomic.Value(?*Task) = .init(null),

unlock_type: UnlockType = .unlocked,

spinlock: kernel.sync.TicketSpinLock = .{},
wait_queue: kernel.sync.WaitQueue = .{},

pub fn lock(mutex: *Mutex) void {
    const current_task: Task.Current = .get();

    while (true) {
        var locked_by = mutex.locked_by.cmpxchgWeak(
            null,
            current_task.task,
            .acquire,
            .monotonic,
        ) orelse {
            // we have the mutex
            return;
        };

        if (locked_by == current_task.task) {
            switch (mutex.unlock_type) {
                .passed_to_waiter => {
                    @branchHint(.likely);
                    // the mutex was passed directly to us
                    return;
                },
                .unlocked => {
                    @branchHint(.cold);
                    @panic("recursive lock");
                },
            }
        }

        mutex.spinlock.lock();

        locked_by = mutex.locked_by.cmpxchgStrong(
            null,
            current_task.task,
            .acquire,
            .monotonic,
        ) orelse {
            // we have the mutex
            mutex.spinlock.unlock();
            return;
        };

        if (locked_by == current_task.task) {
            switch (mutex.unlock_type) {
                .passed_to_waiter => {
                    @branchHint(.likely);
                    // the mutex was passed directly to us
                    mutex.spinlock.unlock();
                    return;
                },
                .unlocked => {
                    @branchHint(.cold);
                    @panic("recursive lock");
                },
            }
        }

        mutex.wait_queue.wait(&mutex.spinlock);
    }
}

/// Try to lock the mutex.
pub fn tryLock(mutex: *Mutex) bool {
    const current_task: Task.Current = .get();

    const locked_by = mutex.locked_by.cmpxchgStrong(
        null,
        current_task.task,
        .acquire,
        .monotonic,
    ) orelse return true;

    if (locked_by == current_task.task) {
        @branchHint(.cold);
        if (core.is_debug) {
            // this could only happen if we were queued for the mutex but then how would we call tryLock?
            std.debug.assert(mutex.unlock_type != .passed_to_waiter);
        }
        @panic("recursive lock");
    }

    return false;
}

pub fn unlock(mutex: *Mutex) void {
    mutex.spinlock.lock();
    defer mutex.spinlock.unlock();

    const current_task: Task.Current = .get();

    const waiting_task = mutex.wait_queue.firstTask() orelse {
        mutex.unlock_type = .unlocked;

        if (mutex.locked_by.cmpxchgStrong(
            current_task.task,
            null,
            .release,
            .monotonic,
        )) |_| {
            @branchHint(.cold);
            @panic("not locked by current task");
        }

        return;
    };

    // pass the mutex directly to the waiting task
    mutex.unlock_type = .passed_to_waiter;

    if (mutex.locked_by.cmpxchgStrong(
        current_task.task,
        waiting_task,
        .release,
        .monotonic,
    )) |_| {
        @branchHint(.cold);
        @panic("not locked by current task");
    }

    mutex.wait_queue.wakeOne(&mutex.spinlock);
}

/// Returns `true` if the mutex is locked.
pub fn isLocked(mutex: *Mutex) bool {
    return mutex.locked_by.load(.monotonic) != null;
}

const UnlockType = enum {
    /// The mutex was passed directly to the first waiting task.
    passed_to_waiter,
    /// The mutex was unlocked normally.
    unlocked,
};

// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A fair in order mutex.
//!
//! Preemption is disabled while locked.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const Mutex = @This();

locked_by: std.atomic.Value(?*Task) = .init(null),

unlock_type: UnlockType = .unlocked,

spinlock: cascade.sync.TicketSpinLock = .{},
wait_queue: cascade.sync.WaitQueue = .{},

pub fn lock(mutex: *Mutex, current_task: Task.Current) void {
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

        mutex.spinlock.lock(current_task);

        locked_by = mutex.locked_by.cmpxchgStrong(
            null,
            current_task.task,
            .acquire,
            .monotonic,
        ) orelse {
            // we have the mutex
            mutex.spinlock.unlock(current_task);
            return;
        };

        if (locked_by == current_task.task) {
            switch (mutex.unlock_type) {
                .passed_to_waiter => {
                    @branchHint(.likely);
                    // the mutex was passed directly to us
                    mutex.spinlock.unlock(current_task);
                    return;
                },
                .unlocked => {
                    @branchHint(.cold);
                    @panic("recursive lock");
                },
            }
        }

        mutex.wait_queue.wait(current_task, &mutex.spinlock);
    }
}

/// Try to lock the mutex.
pub fn tryLock(mutex: *Mutex, current_task: Task.Current) bool {
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

pub fn unlock(mutex: *Mutex, current_task: Task.Current) void {
    {
        mutex.spinlock.lock(current_task);
        defer mutex.spinlock.unlock(current_task);

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

        mutex.wait_queue.wakeOne(current_task, &mutex.spinlock);
    }
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

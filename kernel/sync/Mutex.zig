// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A fair in order mutex.
//!
//! Preemption is disabled while locked.

const Mutex = @This();

locked_by: std.atomic.Value(?*kernel.Task) = .init(null),

/// `true` when the mutex is passed directly to a waiter on unlock.
passed_to_waiter: bool = false,

spinlock: kernel.sync.TicketSpinLock = .{},
wait_queue: kernel.sync.WaitQueue = .{},

pub fn lock(mutex: *Mutex, current_task: *kernel.Task) void {
    while (true) {
        current_task.incrementPreemptionDisable();

        var locked_by = mutex.locked_by.cmpxchgWeak(
            null,
            current_task,
            .acquire,
            .monotonic,
        ) orelse {
            // we have the mutex
            return;
        };

        if (locked_by == current_task) {
            if (mutex.passed_to_waiter) {
                @branchHint(.likely);
                mutex.passed_to_waiter = false;
                return;
            } else {
                @branchHint(.cold);
                @panic("recursive lock");
            }
        }

        mutex.spinlock.lock(current_task);

        locked_by = mutex.locked_by.cmpxchgStrong(
            null,
            current_task,
            .acquire,
            .monotonic,
        ) orelse {
            // we have the mutex
            mutex.spinlock.unlock(current_task);
            return;
        };

        if (locked_by == current_task) {
            @branchHint(.cold);
            @panic("recursive lock");
        }

        current_task.decrementPreemptionDisable();

        mutex.wait_queue.wait(current_task, &mutex.spinlock);
    }
}

/// Try to lock the mutex.
pub fn tryLock(mutex: *Mutex, current_task: *kernel.Task) bool {
    current_task.incrementPreemptionDisable();

    const locked_by = mutex.locked_by.cmpxchgStrong(
        null,
        current_task,
        .acquire,
        .monotonic,
    ) orelse return true;

    if (locked_by == current_task) {
        @branchHint(.cold);
        std.debug.assert(!mutex.passed_to_waiter); // this should never happen

        @panic("recursive lock");
    }

    current_task.decrementPreemptionDisable();

    return false;
}

pub fn unlock(mutex: *Mutex, current_task: *kernel.Task) void {
    defer current_task.decrementPreemptionDisable();

    mutex.spinlock.lock(current_task);
    defer mutex.spinlock.unlock(current_task);

    const waiting_task = mutex.wait_queue.firstTask() orelse {
        if (mutex.locked_by.cmpxchgStrong(
            current_task,
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

    std.debug.assert(mutex.passed_to_waiter == false);
    mutex.passed_to_waiter = true;

    if (mutex.locked_by.cmpxchgStrong(
        current_task,
        waiting_task,
        .release,
        .monotonic,
    )) |_| {
        @branchHint(.cold);
        @panic("not locked by current task");
    }

    mutex.wait_queue.wakeOne(current_task, &mutex.spinlock);
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

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
            .acq_rel,
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
            .acq_rel,
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

pub fn unlock(mutex: *Mutex, current_task: *kernel.Task) void {
    defer current_task.decrementPreemptionDisable();

    mutex.spinlock.lock(current_task);
    defer mutex.spinlock.unlock(current_task);

    if (mutex.wait_queue.firstTask()) |waiting_task| {
        // pass the mutex directly to the waiting task

        std.debug.assert(mutex.passed_to_waiter == false);
        mutex.passed_to_waiter = true;

        if (mutex.locked_by.cmpxchgStrong(
            current_task,
            waiting_task,
            .acq_rel,
            .monotonic,
        )) |_| {
            @branchHint(.cold);
            @panic("not locked by current task");
        }

        mutex.wait_queue.wakeOne(current_task, &mutex.spinlock);
    } else {
        if (mutex.locked_by.cmpxchgStrong(
            current_task,
            null,
            .acq_rel,
            .monotonic,
        )) |_| {
            @branchHint(.cold);
            @panic("not locked by current task");
        }
    }
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

const Mutex = @This();

locked_by: std.atomic.Value(?*kernel.Task) align(std.atomic.cache_line) = .init(null),

spinlock: kernel.sync.TicketSpinLock = .{},
wait_queue: kernel.sync.WaitQueue = .{},

pub fn lock(mutex: *Mutex, current_task: *kernel.Task) void {
    while (true) {
        current_task.incrementPreemptionDisable();

        for (0..spins) |_| {
            _ = mutex.locked_by.cmpxchgWeak(
                null,
                current_task,
                .acq_rel,
                .monotonic,
            ) orelse {
                // we have the mutex
                return;
            };
            kernel.arch.spinLoopHint();
        }

        mutex.spinlock.lock(current_task);

        const locked_by = mutex.locked_by.cmpxchgStrong(
            null,
            current_task,
            .acq_rel,
            .monotonic,
        ) orelse {
            // we have the mutex
            mutex.spinlock.unlock(current_task);
            return;
        };
        std.debug.assert(locked_by != current_task); // recursive lock

        current_task.decrementPreemptionDisable();

        mutex.wait_queue.wait(current_task, &mutex.spinlock);
    }
}

pub fn unlock(mutex: *Mutex, current_task: *kernel.Task) void {
    defer current_task.decrementPreemptionDisable();

    if (mutex.locked_by.cmpxchgStrong(
        current_task,
        null,
        .acq_rel,
        .monotonic,
    )) |_| {
        @panic("not locked by current task");
    }

    mutex.spinlock.lock(current_task);
    defer mutex.spinlock.unlock(current_task);

    if (mutex.locked_by.load(.acquire) == null) {
        return;
    }

    mutex.wait_queue.wakeOne(current_task);
}

const spins = 10;

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

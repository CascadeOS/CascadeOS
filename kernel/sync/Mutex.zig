// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

const Mutex = @This();

spinlock: kernel.sync.TicketSpinLock = .{},
wait_queue: kernel.sync.WaitQueue = .{},

locked_by: ?*kernel.Task = null,

pub fn lock(mutex: *Mutex, current_task: *kernel.Task) void {
    while (true) {
        mutex.spinlock.lock(current_task);

        const locked_by = mutex.locked_by orelse {
            mutex.locked_by = current_task;

            current_task.incrementPreemptionDisable();
            mutex.spinlock.unlock(current_task);

            return;
        };
        std.debug.assert(locked_by != current_task); // recursive lock

        mutex.wait_queue.wait(current_task, &mutex.spinlock);
    }
}

pub fn unlock(mutex: *Mutex, current_task: *kernel.Task) void {
    mutex.spinlock.lock(current_task);

    std.debug.assert(mutex.locked_by == current_task);

    mutex.locked_by = null;

    mutex.wait_queue.wakeOne(current_task);

    mutex.spinlock.unlock(current_task);

    current_task.decrementPreemptionDisable();
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const Mutex = @This();

spinlock: kernel.sync.TicketSpinLock = .{},
wait_queue: kernel.sync.WaitQueue = .{},

locked_by: ?*kernel.Task = null,

pub fn lock(mutex: *Mutex, context: *kernel.Context) void {
    while (true) {
        const spinlock_held = mutex.spinlock.lock(context);

        const current_task = context.task;

        const locked_by = mutex.locked_by orelse {
            mutex.locked_by = current_task;

            context.incrementPreemptionDisable();
            spinlock_held.unlock();

            return;
        };

        std.debug.assert(current_task.idle_for == null); // block during idle
        std.debug.assert(locked_by == current_task); // recursive lock

        mutex.wait_queue.wait(context, current_task, spinlock_held);

        continue;
    }
}

pub fn unlock(mutex: *Mutex, context: *kernel.Context) void {
    const spinlock_held = mutex.spinlock.lock(context);
    defer spinlock_held.unlock();

    std.debug.assert(mutex.locked_by == context.task);
    mutex.locked_by = null;

    mutex.wait_queue.wakeOne(context);

    context.decrementPreemptionDisable();
}

/// Returns true if the mutex is locked by the current task.
pub fn isLockedByCurrent(mutex: *const Mutex, context: *const kernel.Context) bool {
    return context.task == mutex.locked_by;
}

const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const std = @import("std");
const containers = @import("containers");

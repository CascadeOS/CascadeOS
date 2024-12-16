// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const Mutex = @This();

spinlock: kernel.sync.TicketSpinLock = .{},
wait_queue: kernel.sync.WaitQueue = .{},

locked: bool = false,
locked_by: ?*kernel.Task = null,

pub fn lock(mutex: *Mutex) void {
    while (true) {
        var exclusion = kernel.sync.acquireInterruptExclusion();
        defer exclusion.release();

        var spinlock_held = mutex.spinlock.lock(&exclusion);

        const opt_current_task = exclusion.getCurrentExecutor().current_task;

        if (!mutex.locked) {
            mutex.locked = true;
            mutex.locked_by = opt_current_task;

            if (opt_current_task) |current_task| current_task.preemption_disable_count += 1;

            spinlock_held.unlock();

            return;
        }

        const current_task = opt_current_task orelse core.panic(
            "Mutex.acquire with no current task would block",
            null,
        );

        std.debug.assert(mutex.locked_by != current_task);

        mutex.wait_queue.wait(current_task, spinlock_held);
    }
}

pub fn unlock(mutex: *Mutex) void {
    const opt_current_task = blk: {
        var exclusion = kernel.sync.acquireInterruptExclusion();
        defer exclusion.release();

        var spinlock_held = mutex.spinlock.lock(&exclusion);
        defer spinlock_held.unlock();

        const opt_current_task = exclusion.getCurrentExecutor().current_task;

        std.debug.assert(mutex.locked_by == opt_current_task);

        mutex.locked = false;
        mutex.locked_by = null;

        mutex.wait_queue.wakeOne(&exclusion);

        break :blk opt_current_task;
    };

    if (opt_current_task) |current_task| {
        current_task.preemption_disable_count -= 1;
        if (current_task.preemption_disable_count == 0 and current_task.preemption_skipped) {
            var exclusion = kernel.sync.acquireInterruptExclusion();
            defer exclusion.release();

            kernel.scheduler.maybePreempt(&exclusion);
        }
    }
}

/// Returns true if the mutex is locked by the current task.
pub fn isLockedByCurrent(mutex: *const Mutex) bool {
    if (!mutex.locked) return false;
    return arch.rawGetCurrentExecutor().current_task == mutex.locked_by;
}

const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const std = @import("std");
const containers = @import("containers");

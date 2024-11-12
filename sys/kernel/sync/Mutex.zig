// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const Mutex = @This();

spinlock: kernel.sync.TicketSpinLock = .{},
wait_queue: kernel.sync.WaitQueue = .{},

locked_by: ?*kernel.Task = null,

pub const Held = struct {
    mutex: *Mutex,

    pub fn unlock(self: Held) void {
        const mutex = self.mutex;

        const opt_current_task = blk: {
            var exclusion = kernel.sync.acquireInterruptExclusion();
            defer exclusion.release();

            var spinlock_held = mutex.spinlock.lock(exclusion);
            defer spinlock_held.unlock();

            const opt_current_task = exclusion.executor.current_task;

            std.debug.assert(mutex.locked_by == opt_current_task);

            mutex.locked_by = null;

            self.mutex.wait_queue.wakeOne(exclusion);

            break :blk opt_current_task;
        };

        if (opt_current_task) |current_task| {
            current_task.preemption_disable_count -= 1;
            if (current_task.preemption_disable_count == 0 and current_task.preemption_skipped) {
                var exclusion = kernel.sync.acquireInterruptExclusion();
                defer exclusion.release();

                var scheduler_held = kernel.scheduler.lockScheduler(exclusion);
                defer scheduler_held.unlock();

                kernel.scheduler.maybePreempt(scheduler_held);
            }
        }
    }
};

pub fn lock(mutex: *Mutex) Held {
    while (true) {
        var exclusion = kernel.sync.acquireInterruptExclusion();
        defer exclusion.release();

        var spinlock_held = mutex.spinlock.lock(exclusion);

        const opt_current_task = exclusion.executor.current_task;

        if (mutex.locked_by == null) {
            mutex.locked_by = opt_current_task;

            if (opt_current_task) |current_task| current_task.preemption_disable_count += 1;

            spinlock_held.unlock();

            return .{ .mutex = mutex };
        }

        const current_task = opt_current_task orelse core.panic(
            "Mutex.acquire with no current task would block",
            null,
        );

        std.debug.assert(mutex.locked_by != current_task);

        mutex.wait_queue.wait(current_task, spinlock_held);
    }
}

const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const std = @import("std");
const containers = @import("containers");

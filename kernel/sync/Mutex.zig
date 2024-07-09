// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const Mutex = @This();

spinlock: kernel.sync.TicketSpinLock = .{},
wait_queue: kernel.sync.WaitQueue = .{},

locked: bool = false,
locked_by: ?*kernel.Task = null,

pub const Held = struct {
    mutex: *Mutex,

    pub fn release(self: Held) void {
        const mutex = self.mutex;

        core.debugAssert(mutex.locked);

        const opt_current_task = blk: {
            const spinlock_held = mutex.spinlock.acquire();
            defer spinlock_held.release();

            const opt_current_task = spinlock_held.exclusion.cpu.current_task;

            core.debugAssert(mutex.locked_by == opt_current_task);

            mutex.locked = false;
            mutex.locked_by = null;

            self.mutex.wait_queue.wakeOne();

            break :blk opt_current_task;
        };

        if (opt_current_task) |current_task| {
            current_task.preemption_disable_count -= 1;
            if (current_task.preemption_disable_count == 0 and current_task.preemption_skipped) {
                const scheduler_held = kernel.scheduler.acquireScheduler();
                defer scheduler_held.release();

                kernel.scheduler.maybePreempt(scheduler_held);
            }
        }
    }
};

pub fn acquire(mutex: *Mutex) Held {
    while (true) {
        const spinlock_held = mutex.spinlock.acquire();

        const opt_current_task = spinlock_held.exclusion.cpu.current_task;

        if (!mutex.locked) {
            mutex.locked = true;
            mutex.locked_by = opt_current_task;

            if (opt_current_task) |current_task| current_task.preemption_disable_count += 1;

            spinlock_held.release();

            return .{ .mutex = mutex };
        }

        const current_task = opt_current_task orelse core.panic("Mutex.acquire with no current task would block");

        core.debugAssert(mutex.locked_by != current_task);

        mutex.wait_queue.wait(current_task, &mutex.spinlock);
    }
}

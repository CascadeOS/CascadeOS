// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const log = kernel.log.scoped(.mutex);

const Mutex = @This();

spinlock: kernel.sync.TicketSpinLock = .{},
waiting_tasks: containers.SinglyLinkedFIFO = .{},

locked: bool = false,
locked_by: ?*kernel.Task = null,

pub const Held = struct {
    mutex: *Mutex,

    pub fn release(self: Held) void {
        const mutex = self.mutex;

        core.debugAssert(mutex.locked);

        const spinlock_held = mutex.spinlock.acquire();

        const opt_current_task = spinlock_held.exclusion.cpu.current_task;

        core.debugAssert(mutex.locked_by == opt_current_task);

        mutex.locked = false;
        mutex.locked_by = null;

        const task_to_wake_node = mutex.waiting_tasks.pop() orelse {
            spinlock_held.release();
            log.debug("{?} released {*} no waiters", .{ opt_current_task, mutex });
            return;
        };
        const task_to_wake = kernel.Task.fromNode(task_to_wake_node);

        log.debug("{?} released {*} and waking {}", .{ opt_current_task, mutex, task_to_wake });

        // acquire the scheduler lock before releasing the spin lock
        const scheduler_held = kernel.scheduler.acquireScheduler();
        defer scheduler_held.release();

        spinlock_held.release();

        kernel.scheduler.queueTask(scheduler_held, task_to_wake);
    }
};

pub fn acquire(mutex: *Mutex) Held {
    while (true) {
        const spinlock_held = mutex.spinlock.acquire();

        const opt_current_task = spinlock_held.exclusion.cpu.current_task;

        if (!mutex.locked) {
            mutex.locked = true;
            mutex.locked_by = opt_current_task;

            // TODO: disable preemption?

            spinlock_held.release();

            log.debug("{?} acquired {*}", .{ opt_current_task, mutex });

            return .{ .mutex = mutex };
        }

        const current_task = opt_current_task orelse core.panic("Mutex.acquire with no current task would block");

        core.debugAssert(mutex.locked_by != current_task);

        log.debug("{} failed to acquire {*}, waiting", .{ current_task, mutex });

        current_task.next_task_node = .{};
        mutex.waiting_tasks.push(&current_task.next_task_node);

        // acquire the scheduler lock before releasing the spin lock
        const scheduler_held = kernel.scheduler.acquireScheduler();
        defer scheduler_held.release();

        spinlock_held.release();

        kernel.scheduler.block(scheduler_held);
    }
}

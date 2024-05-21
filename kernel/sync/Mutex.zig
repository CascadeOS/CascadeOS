// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const Mutex = @This();

spinlock: kernel.sync.TicketSpinLock = .{},
waiting_threads: containers.SinglyLinkedFIFO = .{},

locked: bool = false,
locked_by: ?*kernel.Thread = null,

pub const Held = struct {
    mutex: *Mutex,

    pub fn release(self: Held) void {
        const mutex = self.mutex;

        core.debugAssert(mutex.locked);

        const interrupt_exclusion = kernel.sync.getInterruptExclusion();

        core.debugAssert(mutex.locked_by == interrupt_exclusion.cpu.current_thread);

        const opt_thread_to_wake_node = blk: {
            const held = mutex.spinlock.acquire();
            defer held.release();

            mutex.locked = false;
            mutex.locked_by = null;

            break :blk mutex.waiting_threads.pop();
        };

        if (opt_thread_to_wake_node) |thread_to_wake_node| {
            const thread_to_wake = kernel.Thread.fromNode(thread_to_wake_node);
            thread_to_wake_node.* = .{};

            const held = kernel.scheduler.acquireScheduler();
            defer held.release();

            interrupt_exclusion.release();

            kernel.scheduler.queueThread(held, thread_to_wake);
        } else {
            interrupt_exclusion.release();
        }
    }
};

pub fn acquire(mutex: *Mutex) Held {
    while (true) {
        const mutex_lock = mutex.spinlock.acquire();

        const current_thread = mutex_lock.exclusion.cpu.current_thread orelse
            core.panic("Mutex.acquire called with no current thread");

        if (!mutex.locked) {
            mutex.locked = true;
            mutex.locked_by = current_thread;

            // TODO: disable preemption?

            mutex_lock.release();
            return .{ .mutex = mutex };
        }
        core.debugAssert(mutex.locked_by != current_thread);

        current_thread.state = .waiting;
        current_thread.next_thread_node = .{};
        mutex.waiting_threads.push(&current_thread.next_thread_node);

        const scheduler_held = kernel.scheduler.acquireScheduler();
        defer scheduler_held.release();

        mutex_lock.release();

        kernel.scheduler.schedule(scheduler_held);
    }
}

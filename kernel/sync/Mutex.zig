// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const log = kernel.log.scoped(.mutex);

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

        const spinlock_held = mutex.spinlock.acquire();

        const current_thread = spinlock_held.exclusion.cpu.current_thread.?;

        core.debugAssert(mutex.locked_by == current_thread);

        mutex.locked = false;
        mutex.locked_by = null;

        const thread_to_wake_node = mutex.waiting_threads.pop() orelse {
            spinlock_held.release();
            log.debug("{} released {*} no waiters", .{ current_thread, mutex });
            return;
        };
        const thread_to_wake = kernel.Thread.fromNode(thread_to_wake_node);

        log.debug("{} released {*} and waking {}", .{ current_thread, mutex, thread_to_wake });

        // acquire the scheduler lock before releasing the spin lock
        const scheduler_held = kernel.scheduler.acquireScheduler();
        defer scheduler_held.release();

        spinlock_held.release();

        kernel.scheduler.queueThread(scheduler_held, thread_to_wake);
    }
};

pub fn acquire(mutex: *Mutex) Held {
    while (true) {
        const spinlock_held = mutex.spinlock.acquire();

        const current_thread = spinlock_held.exclusion.cpu.current_thread orelse
            core.panic("Mutex.acquire called with no current thread");

        if (!mutex.locked) {
            mutex.locked = true;
            mutex.locked_by = current_thread;

            // TODO: disable preemption?

            spinlock_held.release();

            log.debug("{} acquired {*}", .{ current_thread, mutex });

            return .{ .mutex = mutex };
        }
        core.debugAssert(mutex.locked_by != current_thread);

        log.debug("{} failed to acquire {*}, waiting", .{ current_thread, mutex });

        current_thread.state = .waiting;
        current_thread.next_thread_node = .{};
        mutex.waiting_threads.push(&current_thread.next_thread_node);

        // acquire the scheduler lock before releasing the spin lock
        const scheduler_held = kernel.scheduler.acquireScheduler();
        defer scheduler_held.release();

        spinlock_held.release();

        kernel.scheduler.schedule(scheduler_held);
    }
}

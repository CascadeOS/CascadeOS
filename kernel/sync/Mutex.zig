// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const log = kernel.log.scoped(.mutex);

const Mutex = @This();

spinlock: kernel.sync.TicketSpinLock = .{},
locked_by: ?*kernel.Thread = null,
waiting_threads: containers.SinglyLinkedFIFO = .{},

pub const Held = struct {
    preemption_halt: kernel.sync.PreemptionHalt,
    mutex: *Mutex,

    pub fn release(self: Held) void {
        const mutex = self.mutex;

        const current_thread = self.preemption_halt.cpu.current_thread.?; // idle should never acquire a mutex
        core.debugAssert(mutex.locked_by == current_thread);

        const opt_thread_to_wake_node = blk: {
            const held = mutex.spinlock.lock();
            defer held.release();

            mutex.locked_by = null;

            break :blk mutex.waiting_threads.pop();
        };

        if (opt_thread_to_wake_node) |thread_to_wake_node| {
            const thread_to_wake = kernel.Thread.fromNode(thread_to_wake_node);
            thread_to_wake_node.* = .{};

            log.debug("{} released mutex and waking {}", .{ current_thread, thread_to_wake });

            const held = kernel.scheduler.lockScheduler();
            self.preemption_halt.release();
            defer held.release();

            kernel.scheduler.queueThread(held, thread_to_wake);
        } else {
            self.preemption_halt.release();
            log.debug("{} released mutex", .{current_thread});
        }
    }
};

pub fn acquire(self: *Mutex) Held {
    while (true) {
        const mutex_lock = self.spinlock.lock();

        const current_thread = mutex_lock.preemption_interrupt_halt.cpu.current_thread.?; // idle should never acquire a mutex

        if (self.locked_by == null) {
            self.locked_by = current_thread;

            const preemption_halt = kernel.sync.getCpuPreemptionHalt();

            mutex_lock.release();

            log.debug("{} acquired mutex", .{current_thread});

            return .{
                .mutex = self,
                .preemption_halt = preemption_halt,
            };
        }
        core.debugAssert(self.locked_by != current_thread);

        log.debug("{} now waiting for mutex", .{current_thread});

        current_thread.state = .waiting;
        current_thread.next_thread_node = .{};
        self.waiting_threads.push(&current_thread.next_thread_node);

        const scheduler_held = kernel.scheduler.lockScheduler();
        mutex_lock.release();
        kernel.scheduler.schedule(scheduler_held);
        scheduler_held.release();
    }
}

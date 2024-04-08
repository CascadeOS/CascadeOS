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
    preemption_halt: kernel.sync.PreemptionHalt,
    mutex: *Mutex,

    pub fn release(self: Held) void {
        const mutex = self.mutex;

        core.debugAssert(mutex.locked);
        core.debugAssert(mutex.locked_by == self.preemption_halt.cpu.current_thread);

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
            self.preemption_halt.release();
            defer held.release();

            kernel.scheduler.queueThread(held, thread_to_wake);
        } else {
            self.preemption_halt.release();
        }
    }
};

pub fn acquire(self: *Mutex) Held {
    while (true) {
        const mutex_lock = self.spinlock.acquire();

        const opt_current_thread = mutex_lock.preemption_interrupt_halt.cpu.current_thread;

        if (!self.locked) {
            self.locked = true;
            self.locked_by = opt_current_thread;

            const preemption_halt = kernel.sync.getCpuPreemptionHalt();

            mutex_lock.release();

            return .{
                .mutex = self,
                .preemption_halt = preemption_halt,
            };
        }
        core.debugAssert(self.locked_by != opt_current_thread);

        const current_thread = opt_current_thread orelse {
            core.panic("blocked on mutex with no thread (maybe during init?)");
        };

        current_thread.state = .waiting;
        current_thread.next_thread_node = .{};
        self.waiting_threads.push(&current_thread.next_thread_node);

        const scheduler_held = kernel.scheduler.acquireScheduler();
        mutex_lock.release();
        kernel.scheduler.schedule(scheduler_held);
        scheduler_held.release();
    }
}

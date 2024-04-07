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
    preemption_halt: kernel.sync.PreemptionHalt,
    mutex: *Mutex,

    pub fn release(self: Held) void {
        const mutex = self.mutex;

        const opt_current_thread = self.preemption_halt.cpu.current_thread;
        core.debugAssert(mutex.locked_by == opt_current_thread);

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

            if (opt_current_thread) |current_thread| {
                log.debug("{} released mutex and waking {}", .{ current_thread, thread_to_wake });
            } else {
                // TODO: this is why kernel init should happen in a thread instead of "idle"
                core.panic("kernel init attempting to wake another thread?");
            }

            const held = kernel.scheduler.acquireScheduler();
            self.preemption_halt.release();
            defer held.release();

            kernel.scheduler.queueThread(held, thread_to_wake);
        } else {
            self.preemption_halt.release();
            if (opt_current_thread) |current_thread| {
                log.debug("{} released mutex", .{current_thread});
            } else {
                // TODO: this is why kernel init should happen in a thread instead of "idle"
                log.debug("kernel init released mutex", .{});
            }
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

            if (opt_current_thread) |current_thread| {
                log.debug("{} acquired mutex", .{current_thread});
            } else {
                // TODO: this is why kernel init should happen in a thread instead of "idle"
                log.debug("kernel init acquired mutex", .{});
            }

            return .{
                .mutex = self,
                .preemption_halt = preemption_halt,
            };
        }
        core.debugAssert(self.locked_by != opt_current_thread);

        const current_thread = opt_current_thread orelse {
            // TODO: this is why kernel init should happen in a thread instead of "idle"
            core.panic("blocked on mutex with no thread (maybe during init?)");
        };

        log.debug("{} now waiting for mutex", .{current_thread});

        current_thread.state = .waiting;
        current_thread.next_thread_node = .{};
        self.waiting_threads.push(&current_thread.next_thread_node);

        const scheduler_held = kernel.scheduler.acquireScheduler();
        mutex_lock.release();
        kernel.scheduler.schedule(scheduler_held);
        scheduler_held.release();
    }
}

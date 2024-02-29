// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! A simple round robin scheduler.

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

pub const Process = @import("Process.zig");
pub const Thread = @import("Thread.zig");

const log = kernel.debug.log.scoped(.scheduler);

pub var lock: kernel.SpinLock = .{};

var ready_to_run_start: ?*Thread = null;
var ready_to_run_end: ?*Thread = null;

const time_slice = core.Duration.from(5, .millisecond);

pub const Priority = enum(u4) {
    idle = 0,
    background_kernel = 1,
    user = 2,
    normal_kernel = 3,
};

/// Performs a round robin scheduling of the ready threads.
///
/// If `requeue_current_thread` is set to true, the current thread will be requeued before the next thread is found.
///
/// The scheduler `lock` must be held when calling this function.
pub fn schedule(requeue_current_thread: bool) void {
    core.debugAssert(lock.isLockedByCurrent());

    const processor = kernel.arch.getProcessor();

    const opt_current_thread = processor.current_thread;

    // We need to requeue the current thread before we find the next thread to run,
    // in case the current thread is the last thread in the ready queue.
    if (requeue_current_thread) {
        if (opt_current_thread) |current_thread| {
            queueThread(current_thread);
        }
    }

    const new_thread = ready_to_run_start orelse {
        // no thread to run
        switchToIdle(processor, opt_current_thread);
        unreachable;
    };

    // update the ready queue
    ready_to_run_start = new_thread.next_thread;
    if (new_thread == ready_to_run_end) ready_to_run_end = null;

    new_thread.next_thread = null;

    const current_thread = opt_current_thread orelse {
        // we were previously idle
        switchToThreadFromIdle(processor, new_thread);
        unreachable;
    };

    // if we are already running the new thread, no switch is required
    if (new_thread == current_thread) {
        log.debug("already running new thread", .{});
        return;
    }

    switchToThreadFromThread(processor, current_thread, new_thread);
}

/// Queues a thread to be run by the scheduler.
///
/// The scheduler `lock` must be held when calling this function.
pub fn queueThread(thread: *Thread) void {
    core.debugAssert(lock.isLockedByCurrent());
    core.debugAssert(thread.next_thread == null);

    thread.state = .ready;

    if (ready_to_run_end) |last_thread| {
        last_thread.next_thread = thread;
        ready_to_run_end = thread;
    } else {
        ready_to_run_start = thread;
        ready_to_run_end = thread;
    }
}

fn switchToIdle(processor: *kernel.Processor, opt_current_thread: ?*Thread) noreturn {
    log.debug("no threads to run, switching to idle", .{});

    const idle_stack_pointer = processor.idle_stack.pushReturnAddressWithoutChangingPointer(
        core.VirtualAddress.fromPtr(&idle),
    ) catch unreachable; // the idle stack is always big enough to hold a return address

    processor.current_thread = null;
    kernel.arch.interrupts.setTaskPriority(.idle);

    kernel.arch.scheduling.switchToIdle(processor, idle_stack_pointer, opt_current_thread);
    unreachable;
}

fn switchToThreadFromIdle(processor: *kernel.Processor, new_thread: *Thread) noreturn {
    log.debug("switching to {} from idle", .{new_thread});

    processor.current_thread = new_thread;
    new_thread.state = .running;
    kernel.arch.interrupts.setTaskPriority(new_thread.priority);

    kernel.arch.scheduling.switchToThreadFromIdle(processor, new_thread);
    unreachable;
}

fn switchToThreadFromThread(processor: *kernel.Processor, current_thread: *Thread, new_thread: *Thread) void {
    log.debug("switching to {} from {}", .{ new_thread, current_thread });

    processor.current_thread = new_thread;
    new_thread.state = .running;
    kernel.arch.interrupts.setTaskPriority(new_thread.priority);

    kernel.arch.scheduling.switchToThreadFromThread(processor, current_thread, new_thread);
}

fn idle() noreturn {
    lock.unsafeUnlock();
    kernel.arch.interrupts.enableInterrupts();

    log.debug("entering idle", .{});

    while (true) {
        if (ready_to_run_start != null) {
            const held = lock.lock();
            defer held.unlock();

            if (ready_to_run_start != null) {
                schedule(false);
                unreachable;
            }
        }

        kernel.arch.halt();
    }
}

pub const init = struct {
    /// Initializes the scheduler.
    ///
    /// This function will be called on each core.
    pub fn initScheduler() void {
        log.debug("set scheduler interrupt period: {}", .{time_slice});
        kernel.time.per_core_periodic.enableSchedulerInterrupt(time_slice);
    }
};

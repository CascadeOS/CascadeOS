// SPDX-License-Identifier: MIT

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
pub fn queueThread(thread: *Thread) void {
    core.debugAssert(lock.isLockedByCurrent());

    thread.state = .ready;

    if (ready_to_run_end) |last_thread| {
        last_thread.next_thread = thread;
        ready_to_run_end = thread;
    } else {
        thread.next_thread = null;
        ready_to_run_start = thread;
        ready_to_run_end = thread;
    }
}

fn switchToIdle(processor: *kernel.Processor, opt_current_thread: ?*Thread) noreturn {
    log.debug("no threads to run, switching to idle", .{});

    const idle_stack_pointer = processor.idle_stack.pushReturnAddressWithoutChangingPointer(
        kernel.VirtualAddress.fromPtr(&idle),
    ) catch unreachable; // the idle stack is always big enough to hold a return address

    processor.current_thread = null;

    kernel.arch.scheduling.switchToIdle(processor, idle_stack_pointer, opt_current_thread);
    unreachable;
}

fn switchToThreadFromIdle(processor: *kernel.Processor, new_thread: *Thread) noreturn {
    log.debug("switching to {} from idle", .{new_thread});

    processor.current_thread = new_thread;
    new_thread.state = .running;

    kernel.arch.scheduling.switchToThreadFromIdle(processor, new_thread);
    unreachable;
}

fn switchToThreadFromThread(processor: *kernel.Processor, current_thread: *Thread, new_thread: *Thread) void {
    log.debug("switching to {} from {}", .{ new_thread, current_thread });

    processor.current_thread = new_thread;
    new_thread.state = .running;

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

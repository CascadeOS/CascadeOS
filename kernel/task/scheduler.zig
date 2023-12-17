// SPDX-License-Identifier: MIT

//! A simple round robin scheduler.

const arch = kernel.arch;
const core = @import("core");
const kernel = @import("kernel");
const Processor = kernel.Processor;
const SpinLock = kernel.sync.SpinLock;
const std = @import("std");
const task = kernel.task;
const VirtualAddress = kernel.VirtualAddress;

const log = kernel.debug.log.scoped(.scheduler);

var scheduler_lock: SpinLock = .{};

var ready_to_run_start: ?*task.Thread = null;
var ready_to_run_end: ?*task.Thread = null;

/// Performs a round robin scheduling of the ready threads.
///
/// If `requeue_current_thread` is set to true, the current thread will be requeued before the next thread is found.
pub fn schedule(requeue_current_thread: bool) void {
    const held = scheduler_lock.lock();
    defer held.unlock();

    const processor = arch.getProcessor();

    const opt_current_thread = processor.current_thread;

    // We need to requeue the current thread before we find the next thread to run,
    // in case the current thread is the last thread in the ready queue.
    if (requeue_current_thread) {
        if (opt_current_thread) |current_thread| {
            queueThreadImpl(current_thread);
        }
    }

    const new_thread = ready_to_run_start orelse {
        // there are no more threads to run, so we need to switch to idle

        log.debug("no threads to run, switching to idle", .{});

        const idle_stack_pointer = processor.idle_stack.pushReturnAddressWithoutChangingPointer(
            VirtualAddress.fromPtr(&idle),
        ) catch unreachable; // the idle stack is always big enough to hold a return address

        processor.current_thread = null;
        arch.scheduling.switchToIdle(processor, idle_stack_pointer, opt_current_thread);
        unreachable;
    };

    // update the ready queue
    ready_to_run_start = new_thread.next_thread;
    if (new_thread == ready_to_run_end) ready_to_run_end = null;

    const current_thread = opt_current_thread orelse {
        // switch to the thread from idle

        log.debug("switching to {} from idle", .{new_thread});

        processor.current_thread = new_thread;
        new_thread.state = .running;
        arch.scheduling.switchToThreadFromIdle(processor, new_thread);
        unreachable;
    };

    // if we are already running the new thread, no switch is required
    if (new_thread == current_thread) {
        log.debug("already running new thread", .{});
        return;
    }

    // switch to the new thread
    log.debug("switching to {} from {}", .{ new_thread, current_thread });
    processor.current_thread = new_thread;
    new_thread.state = .running;
    arch.scheduling.switchToThreadFromThread(processor, current_thread, new_thread);
}

/// Queues a thread to be run by the scheduler.
pub fn queueThread(thread: *task.Thread) void {
    const held = scheduler_lock.lock();
    defer held.unlock();

    @call(.always_inline, queueThreadImpl, .{thread});
}

/// Queues a thread to be run by the scheduler.
///
/// The `scheduler_lock` must be held when calling this function.
fn queueThreadImpl(thread: *task.Thread) void {
    core.debugAssert(scheduler_lock.isLockedByCurrent());

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

fn idle() noreturn {
    unsafeUnlockScheduler();
    arch.interrupts.enableInterrupts();

    while (true) {
        if (ready_to_run_start != null) {
            schedule(false);
            unreachable;
        }

        arch.halt();
    }
}

/// Unlocks the scheduler lock.
///
/// It is the callers responsibility to ensure the current processor has the lock.
pub fn unsafeUnlockScheduler() void {
    core.debugAssert(scheduler_lock.isLockedByCurrent());
    scheduler_lock.unsafeUnlock();
}

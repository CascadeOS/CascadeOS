// SPDX-License-Identifier: MIT

const arch = kernel.arch;
const core = @import("core");
const kernel = @import("kernel");
const Processor = kernel.Processor;
const SpinLock = kernel.SpinLock;
const std = @import("std");
const Thread = kernel.Process.Thread;
const VirtualAddress = kernel.VirtualAddress;

// TODO: Replace this simple round robin with a proper scheduler

var scheduler_lock: SpinLock = .{};

var ready_to_run_start: ?*Thread = null;
var ready_to_run_end: ?*Thread = null;

pub noinline fn schedule(requeue_current_thread: bool) void {
    const held = scheduler_lock.lock();
    defer held.unlock();

    const processor = Processor.get();

    const opt_current_thread = processor.current_thread;

    // We need to requeue the current thread before we find the next thread to run,
    // in case the current thread is the last thread in the ready queue.
    if (requeue_current_thread) {
        if (opt_current_thread) |current_thread| {
            queueThreadImpl(current_thread);
        }
    }

    const next_thread = ready_to_run_start orelse {
        // there are no more threads to run, so we need to switch to idle
        jumpToIdle(processor);
    };

    ready_to_run_start = next_thread.next_thread;
    if (next_thread == ready_to_run_end) ready_to_run_end = null;

    const current_thread = opt_current_thread orelse {
        // we were previously idle
        core.panic("UNIMPLEMENTED: switching to next thread from idle"); // TODO
    };

    // if we are already running the next thread, no switch is required
    if (next_thread == current_thread) return;

    // switch to the next thread
    core.panic("UNIMPLEMENTED: switching to next thread from other thread"); // TODO

}

fn jumpToIdle(processor: *Processor) noreturn {
    const idle_stack_pointer = processor.idle_stack.pushReturnAddressWithoutChangingPointer(
        VirtualAddress.fromPtr(&idle),
    ) catch unreachable; // the idle stack is always big enough to hold a return address

    arch.scheduling.changeStackAndReturn(idle_stack_pointer);
}

/// Queues a thread to be run by the scheduler.
pub fn queueThread(thread: *Thread) void {
    const held = scheduler_lock.lock();
    defer held.unlock();

    @call(.always_inline, queueThreadImpl, .{thread});
}

/// Queues a thread to be run by the scheduler.
///
/// The `scheduler_lock` must be held when calling this function.
fn queueThreadImpl(thread: *Thread) void {
    core.debugAssert(scheduler_lock.isLockedByCurrent());

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
    core.debugAssert(scheduler_lock.isLockedByCurrent());

    scheduler_lock.unsafeUnlock();
    arch.interrupts.enableInterrupts();

    while (true) {
        // TODO: improve power management
        arch.halt();
    }
}

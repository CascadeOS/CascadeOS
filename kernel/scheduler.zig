// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.scheduler);

var lock: kernel.sync.TicketSpinLock = .{};
var ready_to_run_start: ?*kernel.Thread = null;
var ready_to_run_end: ?*kernel.Thread = null;

/// Performs a round robin scheduling of the ready threads.
///
/// If `requeue_current_thread` is set to true, the current thread will be requeued before the next thread is found.
///
/// This function must be called with the lock held (see `lockScheduler`).
pub fn schedule(held: kernel.sync.TicketSpinLock.Held, requeue_current_thread: bool) void {
    validateLock(held);

    const cpu = held.cpu_lock.cpu;

    if (cpu.preemption_disable_count > 1) {
        // we have to check for a disable count greater than 1 because grabbing the scheduler lock increments the
        // disable count
        cpu.schedules_skipped += 1;
        return;
    }
    cpu.schedules_skipped = 0;

    const opt_current_thread = cpu.current_thread;

    // We need to requeue the current thread before we find the next thread to run,
    // in case the current thread is the last thread in the ready queue.
    if (requeue_current_thread) {
        if (opt_current_thread) |current_thread| {
            queueThread(held, current_thread);
        }
    }

    const new_thread = ready_to_run_start orelse {
        // no thread to run
        switchToIdle(cpu, opt_current_thread);
        unreachable;
    };

    // update the ready queue
    ready_to_run_start = new_thread.next_thread;
    if (new_thread == ready_to_run_end) ready_to_run_end = null;

    new_thread.next_thread = null;

    const current_thread = opt_current_thread orelse {
        // we were previously idle
        switchToThreadFromIdle(cpu, new_thread);
        unreachable;
    };

    // if we are already running the new thread, no switch is required
    if (new_thread == current_thread) {
        log.debug("already running new thread", .{});
        return;
    }

    switchToThreadFromThread(cpu, current_thread, new_thread);
}
/// Queues a thread to be run by the scheduler.
///
/// This function must be called with the lock held (see `lockScheduler`).
pub fn queueThread(held: kernel.sync.TicketSpinLock.Held, thread: *kernel.Thread) void {
    validateLock(held);
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

fn switchToIdle(cpu: *kernel.Cpu, opt_current_thread: ?*kernel.Thread) noreturn {
    log.debug("no threads to run, switching to idle", .{});

    const idle_stack_pointer = cpu.idle_stack.pushReturnAddressWithoutChangingPointer(
        core.VirtualAddress.fromPtr(&idle),
    ) catch unreachable; // the idle stack is always big enough to hold a return address

    cpu.current_thread = null;
    // TODO: handle priority

    kernel.arch.scheduling.switchToIdle(cpu, idle_stack_pointer, opt_current_thread);
    unreachable;
}

fn switchToThreadFromIdle(cpu: *kernel.Cpu, new_thread: *kernel.Thread) noreturn {
    log.debug("switching to {} from idle", .{new_thread});

    cpu.current_thread = new_thread;
    new_thread.state = .running;
    // TODO: handle priority

    kernel.arch.scheduling.switchToThreadFromIdle(cpu, new_thread);
    unreachable;
}

fn switchToThreadFromThread(cpu: *kernel.Cpu, current_thread: *kernel.Thread, new_thread: *kernel.Thread) void {
    log.debug("switching to {} from {}", .{ new_thread, current_thread });

    cpu.current_thread = new_thread;
    new_thread.state = .running;
    // TODO: handle priority

    kernel.arch.scheduling.switchToThreadFromThread(cpu, current_thread, new_thread);
}

inline fn validateLock(held: kernel.sync.TicketSpinLock.Held) void {
    core.debugAssert(held.spinlock == &lock);
    core.debugAssert(lock.isLockedByCurrent());
    core.debugAssert(held.cpu_lock.exclusion == .preemption_and_interrupt);
}

/// Locks the scheduler and produces a `TicketSpinLock.Held`.
///
/// It is the caller's responsibility to call `TicketSpinLock.Held.release()` when done.
pub fn lockScheduler() kernel.sync.TicketSpinLock.Held {
    return lock.lock();
}

/// Unlocks the scheduler and produces a `CpuLock`.
///
/// Intended to only be called in idle or a new thread.
pub fn unlockScheduler() kernel.sync.CpuLock {
    const cpu = kernel.arch.rawGetCpu();

    core.debugAssert(lock.isLockedBy(cpu.id));

    lock.unsafeUnlock();

    return .{
        .cpu = cpu,
        .exclusion = .preemption_and_interrupt,
    };
}

fn idle() noreturn {
    unlockScheduler().release();

    log.debug("entering idle", .{});

    while (true) {
        if (ready_to_run_start != null) {
            const held = kernel.scheduler.lockScheduler();
            defer held.release();
            if (ready_to_run_start != null) schedule(held, false);
        }
        kernel.arch.halt();
    }
}

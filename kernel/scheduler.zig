// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const log = kernel.log.scoped(.scheduler);

var lock: kernel.sync.TicketSpinLock = .{};
var ready_to_run: containers.SinglyLinkedFIFO = .{};

/// Performs a round robin scheduling of the ready threads.
///
/// This function must be called with the lock held (see `lockScheduler`).
pub fn schedule(held: kernel.sync.TicketSpinLock.Held) void {
    validateLock(held);

    const cpu = held.preemption_interrupt_halt.cpu;

    if (cpu.preemption_disable_count > 1) {
        // we have to check for a disable count greater than 1 because grabbing the scheduler lock increments the
        // disable count
        cpu.schedule_skipped = true;
        return;
    }
    cpu.schedule_skipped = false;

    const opt_current_thread = cpu.current_thread;

    const new_thread_node = ready_to_run.pop() orelse {
        // no thread to run
        switchToIdle(cpu, opt_current_thread);
        unreachable;
    };
    const new_thread = kernel.Thread.fromNode(new_thread_node);

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
    core.debugAssert(thread.next_thread_node.next == null);

    thread.state = .ready;
    ready_to_run.push(&thread.next_thread_node);
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
}

/// Locks the scheduler and produces a `TicketSpinLock.Held`.
///
/// It is the caller's responsibility to call `TicketSpinLock.Held.release()` when done.
pub fn lockScheduler() kernel.sync.TicketSpinLock.Held {
    return lock.lock();
}

/// Unlocks the scheduler and produces a `kernel.sync.PreemptionInterruptHalt`.
///
/// Intended to only be called in idle or a new thread.
pub fn unlockScheduler() kernel.sync.PreemptionInterruptHalt {
    const cpu = kernel.arch.rawGetCpu();

    core.debugAssert(lock.isLockedBy(cpu.id));
    core.debugAssert(cpu.interrupt_disable_count != 0);
    core.debugAssert(cpu.preemption_disable_count != 0);

    lock.unsafeUnlock();

    return .{ .cpu = cpu };
}

fn idle() noreturn {
    unlockScheduler().release();

    log.debug("entering idle", .{});

    while (true) {
        if (!ready_to_run.isEmpty()) {
            const held = kernel.scheduler.lockScheduler();
            defer held.release();
            if (!ready_to_run.isEmpty()) schedule(held);
        }
        kernel.arch.halt();
    }
}

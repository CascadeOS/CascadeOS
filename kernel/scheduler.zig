// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const log = kernel.log.scoped(.scheduler);

var lock: kernel.sync.TicketSpinLock = .{};
var ready_to_run: containers.SinglyLinkedFIFO = .{};

pub const SchedulerHeld = struct {
    held: kernel.sync.TicketSpinLock.Held,

    pub inline fn release(self: SchedulerHeld) void {
        self.held.release();
    }
};

/// Acquires the scheduler and produces a `SchedulerHeld`.
///
/// It is the caller's responsibility to call `SchedulerHeld.Held.release()` when done.
pub fn acquireScheduler() SchedulerHeld {
    return .{ .held = lock.acquire() };
}

/// Releases the scheduler and produces a `kernel.sync.InterruptExclusion`.
///
/// Intended to only be called in idle or a new thread.
pub fn releaseScheduler() kernel.sync.InterruptExclusion {
    const cpu = kernel.arch.rawGetCpu();

    core.debugAssert(lock.isLockedBy(cpu.id));
    core.debugAssert(cpu.interrupt_disable_count != 0);

    lock.unsafeRelease();

    return .{ .cpu = cpu };
}

/// Yields the currently running thread.
pub fn yield(
    scheduler_held: SchedulerHeld,
    comptime behaviour: enum { wait, ready },
) void {
    validateLock(scheduler_held);

    const cpu = scheduler_held.held.exclusion.cpu;

    core.debugAssert(cpu.current_thread != null);
    core.debugAssert(cpu.interrupt_disable_count == 1);

    const current_thread = cpu.current_thread.?;

    const new_thread_node = ready_to_run.pop() orelse {
        // list is empty
        switch (behaviour) {
            .ready => {
                core.debugAssert(current_thread.state == .ready);
                return;
            },
            .wait => {
                core.debugAssert(current_thread.state == .waiting);
                switchToIdle(cpu, null);
                unreachable;
            },
        }
    };
    const new_thread = kernel.Thread.fromNode(new_thread_node);
    core.debugAssert(current_thread != new_thread);

    queueThread(scheduler_held, current_thread);

    switchToThreadFromThread(cpu, current_thread, new_thread);
}

/// Yield execution to the scheduler from a no thread state like idle or init.
pub fn yieldNoThread(scheduler_held: SchedulerHeld) noreturn {
    validateLock(scheduler_held);

    const cpu = scheduler_held.held.exclusion.cpu;

    core.debugAssert(cpu.current_thread == null);
    core.debugAssert(cpu.interrupt_disable_count == 1);

    const new_thread_node = ready_to_run.pop() orelse {
        // list is empty
        switchToIdle(cpu, null);
        unreachable;
    };
    const new_thread = kernel.Thread.fromNode(new_thread_node);

    // we were previously idle
    switchToThreadFromIdle(cpu, new_thread);
    unreachable;
}

/// Queues a thread to be run by the scheduler.
///
/// This function must be called with the lock held (see `acquireScheduler`).
pub fn queueThread(scheduler_held: SchedulerHeld, thread: *kernel.Thread) void {
    validateLock(scheduler_held);
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

    core.debugAssert(new_thread.next_thread_node.next == null);

    cpu.current_thread = new_thread;
    new_thread.state = .running;
    // TODO: handle priority

    kernel.arch.scheduling.switchToThreadFromIdle(cpu, new_thread);
    unreachable;
}

fn switchToThreadFromThread(cpu: *kernel.Cpu, current_thread: *kernel.Thread, new_thread: *kernel.Thread) void {
    log.debug("switching to {} from {}", .{ new_thread, current_thread });

    core.debugAssert(new_thread.next_thread_node.next == null);

    cpu.current_thread = new_thread;
    new_thread.state = .running;
    // TODO: handle priority

    kernel.arch.scheduling.switchToThreadFromThread(cpu, current_thread, new_thread);
}

inline fn validateLock(scheduler_held: SchedulerHeld) void {
    core.debugAssert(scheduler_held.held.spinlock == &lock);
    core.debugAssert(lock.isLockedByCurrent());
}

fn idle() noreturn {
    const interrupt_exclusion = releaseScheduler();
    core.debugAssert(interrupt_exclusion.cpu.interrupt_disable_count == 1);

    interrupt_exclusion.release();

    log.debug("entering idle", .{});

    while (true) {
        if (!ready_to_run.isEmpty()) {
            const scheduler_held = kernel.scheduler.acquireScheduler();
            defer scheduler_held.release();
            if (!ready_to_run.isEmpty()) yieldNoThread(scheduler_held);
        }

        kernel.arch.halt();
    }
}

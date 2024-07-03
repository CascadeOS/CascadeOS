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
/// Intended to only be called in idle or a new task.
pub fn releaseScheduler() kernel.sync.InterruptExclusion {
    const cpu = kernel.arch.rawGetCpu();

    core.debugAssert(lock.isLockedBy(cpu.id));
    core.debugAssert(cpu.interrupt_disable_count != 0);

    lock.unsafeRelease();

    return .{ .cpu = cpu };
}

/// Blocks the currently running task.
pub fn block(
    scheduler_held: SchedulerHeld,
) void {
    validateLock(scheduler_held);

    const cpu = scheduler_held.held.exclusion.cpu;
    core.debugAssert(cpu.current_task != null);
    core.debugAssert(cpu.interrupt_disable_count == 1);

    const current_task = cpu.current_task.?;
    core.debugAssert(current_task.state == .running);

    current_task.state = .blocked;

    const new_task_node = ready_to_run.pop() orelse {
        switchToIdle(cpu, current_task);
        unreachable;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    core.debugAssert(current_task != new_task);
    core.debugAssert(new_task.state == .ready);

    switchToTaskFromTask(cpu, current_task, new_task);
}

/// Yield execution to the scheduler.
pub fn yield(scheduler_held: SchedulerHeld) void {
    validateLock(scheduler_held);

    const cpu = scheduler_held.held.exclusion.cpu;
    core.debugAssert(cpu.interrupt_disable_count == 1);

    const opt_current_task = cpu.current_task;

    if (opt_current_task) |current_task| {
        core.debugAssert(current_task.state == .running);
        queueTask(scheduler_held, current_task);
    }

    const new_task_node = ready_to_run.pop() orelse {
        switchToIdle(cpu, opt_current_task);
        return;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    core.debugAssert(new_task.state == .ready);

    if (opt_current_task) |current_task| {
        core.debugAssert(current_task != new_task);

        switchToTaskFromTask(cpu, current_task, new_task);
    } else {
        switchToTaskFromIdle(cpu, new_task);
    }
}

/// Queues a task to be run by the scheduler.
///
/// This function must be called with the lock held (see `acquireScheduler`).
pub fn queueTask(scheduler_held: SchedulerHeld, task: *kernel.Task) void {
    validateLock(scheduler_held);
    core.debugAssert(task.next_task_node.next == null);

    task.state = .ready;
    ready_to_run.push(&task.next_task_node);
}

fn switchToIdle(cpu: *kernel.Cpu, opt_current_task: ?*kernel.Task) noreturn {
    log.debug("no tasks to run, switching to idle", .{});

    const idle_stack_pointer = cpu.idle_stack.pushReturnAddressWithoutChangingPointer(
        core.VirtualAddress.fromPtr(&idle),
    ) catch unreachable; // the idle stack is always big enough to hold a return address

    cpu.current_task = null;
    // TODO: handle priority

    kernel.arch.scheduling.switchToIdle(cpu, idle_stack_pointer, opt_current_task);
    unreachable;
}

fn switchToTaskFromIdle(cpu: *kernel.Cpu, new_task: *kernel.Task) noreturn {
    log.debug("switching to {} from idle", .{new_task});

    core.debugAssert(new_task.next_task_node.next == null);

    cpu.current_task = new_task;
    new_task.state = .running;
    // TODO: handle priority

    kernel.arch.scheduling.switchToTaskFromIdle(cpu, new_task);
    unreachable;
}

fn switchToTaskFromTask(cpu: *kernel.Cpu, current_task: *kernel.Task, new_task: *kernel.Task) void {
    log.debug("switching to {} from {}", .{ new_task, current_task });

    core.debugAssert(new_task.next_task_node.next == null);

    cpu.current_task = new_task;
    new_task.state = .running;
    // TODO: handle priority

    kernel.arch.scheduling.switchToTaskFromTask(cpu, current_task, new_task);
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
            if (!ready_to_run.isEmpty()) yield(scheduler_held);
        }

        kernel.arch.halt();
    }
}

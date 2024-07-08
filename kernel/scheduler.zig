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
fn releaseScheduler() kernel.sync.InterruptExclusion {
    const cpu = kernel.arch.rawGetCpu();

    core.debugAssert(lock.isLockedBy(cpu.id));
    core.debugAssert(cpu.interrupt_disable_count != 0);

    lock.unsafeRelease();

    return .{ .cpu = cpu };
}

/// Blocks the currently running task.
///
/// The `spinlock_held` is released by this function, the caller is responsible for acquiring it again if necessary.
///
/// This function must be called with the lock held (see `acquireScheduler`).
pub fn block(
    scheduler_held: SchedulerHeld,
    spinlock_held: kernel.sync.TicketSpinLock.Held,
) void {
    validateLock(scheduler_held);

    const cpu = scheduler_held.held.exclusion.cpu;
    core.debugAssert(cpu.current_task != null);
    core.debugAssert(cpu.interrupt_disable_count == 1);

    const current_task = cpu.current_task.?;
    core.debugAssert(current_task.state == .running);

    current_task.state = .blocked;

    const new_task_node = ready_to_run.pop() orelse {
        switchToIdleWithLock(cpu, current_task, spinlock_held);
        return;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    core.debugAssert(current_task != new_task);
    core.debugAssert(new_task.state == .ready);

    switchToTaskFromTaskWithLock(cpu, current_task, new_task, spinlock_held);
}

/// Yield execution to the scheduler.
///
/// This function must be called with the lock held (see `acquireScheduler`).
pub fn yield(scheduler_held: SchedulerHeld, comptime mode: enum { requeue, drop }) void {
    validateLock(scheduler_held);

    const cpu = scheduler_held.held.exclusion.cpu;
    core.debugAssert(cpu.interrupt_disable_count == 1);

    const new_task_node = ready_to_run.pop() orelse {
        switch (mode) {
            .requeue => return,
            .drop => {
                if (cpu.current_task) |current_task| {
                    core.debugAssert(current_task.state == .running);
                    current_task.state = .dropped;
                }

                switchToIdle(cpu, cpu.current_task);
                return;
            },
        }
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    core.debugAssert(new_task.state == .ready);

    if (cpu.current_task) |current_task| {
        core.debugAssert(current_task != new_task);
        core.debugAssert(current_task.state == .running);

        switch (mode) {
            .requeue => queueTask(scheduler_held, current_task),
            .drop => current_task.state = .dropped,
        }

        switchToTaskFromTask(cpu, current_task, new_task);
    } else {
        switchToTaskFromIdle(cpu, new_task);
        unreachable;
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

fn switchToIdle(cpu: *kernel.Cpu, opt_current_task: ?*kernel.Task) void {
    log.debug("no tasks to run, switching to idle", .{});

    cpu.current_task = null;

    if (opt_current_task) |current_task| {
        kernel.arch.scheduling.prepareForJumpToIdleFromTask(cpu, current_task);
    }

    kernel.arch.scheduling.callZeroArgs(opt_current_task, cpu.scheduler_stack, idle) catch |err| {
        switch (err) {
            error.StackOverflow => unreachable, // the scheduler stack is big enough
        }
    };
}

fn switchToIdleWithLock(cpu: *kernel.Cpu, current_task: *kernel.Task, spinlock_held: kernel.sync.TicketSpinLock.Held) void {
    const static = struct {
        fn idleWithLock(spinlock_held_ptr: u64) callconv(.C) noreturn {
            const held: *const kernel.sync.TicketSpinLock.Held = @ptrFromInt(spinlock_held_ptr);
            held.release();
            idle();
            unreachable;
        }
    };

    log.debug("no tasks to run, switching to idle", .{});

    cpu.current_task = null;

    kernel.arch.scheduling.prepareForJumpToIdleFromTask(cpu, current_task);

    kernel.arch.scheduling.callOneArgs(
        current_task,
        cpu.scheduler_stack,
        static.idleWithLock,
        @intFromPtr(&spinlock_held),
    ) catch |err| {
        switch (err) {
            error.StackOverflow => unreachable, // the scheduler stack is big enough
        }
    };
}

fn switchToTaskFromIdle(cpu: *kernel.Cpu, new_task: *kernel.Task) noreturn {
    log.debug("switching to {} from idle", .{new_task});

    core.debugAssert(new_task.next_task_node.next == null);

    cpu.current_task = new_task;
    new_task.state = .running;

    kernel.arch.scheduling.prepareForJumpToTaskFromIdle(cpu, new_task);
    kernel.arch.scheduling.jumpToTaskFromIdle(new_task);
    unreachable;
}

fn switchToTaskFromTask(cpu: *kernel.Cpu, current_task: *kernel.Task, new_task: *kernel.Task) void {
    log.debug("switching to {} from {}", .{ new_task, current_task });

    core.debugAssert(new_task.next_task_node.next == null);

    cpu.current_task = new_task;
    new_task.state = .running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(cpu, current_task, new_task);
    kernel.arch.scheduling.jumpToTaskFromTask(current_task, new_task);
}

fn switchToTaskFromTaskWithLock(cpu: *kernel.Cpu, current_task: *kernel.Task, new_task: *kernel.Task, spinlock_held: kernel.sync.TicketSpinLock.Held) void {
    const static = struct {
        fn switchToTaskWithLock(new_task_ptr: u64, spinlock_held_ptr: u64) callconv(.C) noreturn {
            const held: *const kernel.sync.TicketSpinLock.Held = @ptrFromInt(spinlock_held_ptr);
            held.release();
            kernel.arch.scheduling.jumpToTaskFromIdle(@ptrFromInt(new_task_ptr));
        }
    };

    log.debug("switching to {} from {}", .{ new_task, current_task });

    core.debugAssert(new_task.next_task_node.next == null);

    cpu.current_task = new_task;
    new_task.state = .running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(cpu, current_task, new_task);
    kernel.arch.scheduling.callTwoArgs(
        current_task,
        cpu.scheduler_stack,
        static.switchToTaskWithLock,
        @intFromPtr(&spinlock_held),
        @intFromPtr(new_task),
    ) catch |err| {
        switch (err) {
            error.StackOverflow => unreachable, // the scheduler stack is big enough
        }
    };
}

inline fn validateLock(scheduler_held: SchedulerHeld) void {
    core.debugAssert(scheduler_held.held.spinlock == &lock);
    core.debugAssert(lock.isLockedByCurrent());
}

fn idle() callconv(.C) noreturn {
    const interrupt_exclusion = releaseScheduler();
    core.debugAssert(interrupt_exclusion.cpu.interrupt_disable_count == 1);

    interrupt_exclusion.release();

    log.debug("entering idle", .{});

    while (true) {
        if (!ready_to_run.isEmpty()) {
            const scheduler_held = kernel.scheduler.acquireScheduler();
            defer scheduler_held.release();
            if (!ready_to_run.isEmpty()) yield(scheduler_held, .requeue);
        }

        kernel.arch.halt();
    }
}

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const log = kernel.log.scoped(.scheduler);

var lock: kernel.sync.TicketSpinLock = .{};
var ready_to_run: containers.SinglyLinkedFIFO = .{};

// TODO: Actually use this value rather than always scheduling the current task out.
const time_slice = core.Duration.from(5, .millisecond);

pub const Priority = enum(u4) {
    idle = 0,
    background_kernel = 1,
    user = 2,
    normal_kernel = 3,
};

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

pub fn maybePreempt(scheduler_held: SchedulerHeld) void {
    validateLock(scheduler_held);

    const cpu = scheduler_held.held.exclusion.cpu;
    core.debugAssert(cpu.interrupt_disable_count == 1); // the scheduler lock

    const current_task: *kernel.Task = cpu.current_task orelse {
        yield(scheduler_held, .requeue);
        return;
    };

    if (current_task.preemption_disable_count != 0) {
        current_task.preemption_skipped = true;
        log.debug("preemption skipped for {}", .{current_task});
        return;
    }

    log.debug("preempting {}", .{current_task});
    current_task.preemption_skipped = false;

    yield(scheduler_held, .requeue);
}

/// Blocks the currently running task.
///
/// The `spinlock` is released by this function, the caller is responsible for acquiring it again if necessary.
///
/// This function must be called with the lock held (see `acquireScheduler`).
pub fn block(
    scheduler_held: SchedulerHeld,
    spinlock: *kernel.sync.TicketSpinLock,
) void {
    validateLock(scheduler_held);

    const cpu = scheduler_held.held.exclusion.cpu;

    core.debugAssert(cpu.current_task != null);
    core.debugAssert(cpu.interrupt_disable_count == 2); // the scheduler lock and the spinlock

    const current_task = cpu.current_task.?;
    core.debugAssert(current_task.state == .running);
    core.debugAssert(current_task.preemption_disable_count == 0);
    core.debugAssert(current_task.preemption_skipped == false);

    log.debug("blocking {}", .{current_task});
    current_task.state = .blocked;

    const new_task_node = ready_to_run.pop() orelse {
        switchToIdleWithLock(cpu, current_task, spinlock);
        return;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    core.debugAssert(current_task != new_task);
    core.debugAssert(new_task.state == .ready);

    switchToTaskFromTaskWithLock(cpu, current_task, new_task, spinlock);
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
            .requeue => {
                log.debug("no tasks to yield too", .{});
                return;
            },
            .drop => {
                if (cpu.current_task) |current_task| {
                    core.debugAssert(current_task.state == .running);
                    log.debug("dropping {}", .{current_task});
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
        core.debugAssert(current_task.preemption_disable_count == 0);
        core.debugAssert(current_task.preemption_skipped == false);

        switch (mode) {
            .requeue => {
                log.debug("yielding {}", .{current_task});
                queueTask(scheduler_held, current_task);
            },
            .drop => {
                log.debug("dropping {}", .{current_task});
                current_task.state = .dropped;
            },
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
        kernel.arch.interrupts.setTaskPriority(.idle);
        kernel.arch.scheduling.prepareForJumpToIdleFromTask(cpu, current_task);
    }

    kernel.arch.scheduling.callZeroArgs(opt_current_task, cpu.scheduler_stack, idle) catch |err| {
        switch (err) {
            error.StackOverflow => unreachable, // the scheduler stack is big enough
        }
    };
}

fn switchToIdleWithLock(cpu: *kernel.Cpu, current_task: *kernel.Task, spinlock: *kernel.sync.TicketSpinLock) void {
    const static = struct {
        fn idleWithLock(spinlock_ptr: u64) callconv(.C) noreturn {
            const ticket_spin_lock: *kernel.sync.TicketSpinLock = @ptrFromInt(spinlock_ptr);
            ticket_spin_lock.unsafeRelease();

            const current_cpu = kernel.arch.rawGetCpu();

            const interrupt_exclusion: kernel.sync.InterruptExclusion = .{ .cpu = current_cpu };
            interrupt_exclusion.release();

            core.debugAssert(current_cpu.interrupt_disable_count == 1); // the scheduler lock

            idle();
            unreachable;
        }
    };

    log.debug("no tasks to run, switching to idle with a lock", .{});

    cpu.current_task = null;

    kernel.arch.interrupts.setTaskPriority(.idle);
    kernel.arch.scheduling.prepareForJumpToIdleFromTask(cpu, current_task);

    kernel.arch.scheduling.callOneArgs(
        current_task,
        cpu.scheduler_stack,
        static.idleWithLock,
        @intFromPtr(spinlock),
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

    kernel.arch.interrupts.setTaskPriority(new_task.priority);

    kernel.arch.scheduling.prepareForJumpToTaskFromIdle(cpu, new_task);
    kernel.arch.scheduling.jumpToTaskFromIdle(new_task);
    unreachable;
}

fn switchToTaskFromTask(cpu: *kernel.Cpu, current_task: *kernel.Task, new_task: *kernel.Task) void {
    log.debug("switching to {} from {}", .{ new_task, current_task });

    core.debugAssert(new_task.next_task_node.next == null);

    cpu.current_task = new_task;
    new_task.state = .running;

    kernel.arch.interrupts.setTaskPriority(new_task.priority);

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(cpu, current_task, new_task);
    kernel.arch.scheduling.jumpToTaskFromTask(current_task, new_task);
}

fn switchToTaskFromTaskWithLock(cpu: *kernel.Cpu, current_task: *kernel.Task, new_task: *kernel.Task, spinlock: *kernel.sync.TicketSpinLock) void {
    const static = struct {
        fn switchToTaskWithLock(spinlock_ptr: u64, new_task_ptr: u64) callconv(.C) noreturn {
            const ticket_spin_lock: *kernel.sync.TicketSpinLock = @ptrFromInt(spinlock_ptr);
            ticket_spin_lock.unsafeRelease();

            const current_cpu = kernel.arch.rawGetCpu();

            const interrupt_exclusion: kernel.sync.InterruptExclusion = .{ .cpu = current_cpu };
            interrupt_exclusion.release();

            core.debugAssert(current_cpu.interrupt_disable_count == 1); // the scheduler is expected to be unlocked by the resumed task

            kernel.arch.scheduling.jumpToTaskFromIdle(@ptrFromInt(new_task_ptr));
            unreachable;
        }
    };

    log.debug("switching to {} from {} with a lock", .{ new_task, current_task });

    core.debugAssert(new_task.next_task_node.next == null);

    cpu.current_task = new_task;
    new_task.state = .running;

    kernel.arch.interrupts.setTaskPriority(new_task.priority);

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(cpu, current_task, new_task);
    kernel.arch.scheduling.callTwoArgs(
        current_task,
        cpu.scheduler_stack,
        static.switchToTaskWithLock,
        @intFromPtr(spinlock),
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

pub const init = struct {
    /// Initializes the scheduler.
    ///
    /// This function will be called on each core.
    pub fn initScheduler() void {
        log.debug("set scheduler interrupt period: {}", .{time_slice});
        kernel.time.per_core_periodic.enableSchedulerInterrupt(time_slice);
    }
};

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be run by the scheduler.
///
/// Must be called with the scheduler lock held.
pub fn queueTask(current_task: *kernel.Task, task: *kernel.Task) void {
    std.debug.assert(globals.lock.isLockedBy(current_task.state.running.id));
    std.debug.assert(task.state == .ready);
    std.debug.assert(!task.is_idle_task); // cannot queue an idle task

    globals.ready_to_run.push(&task.next_task_node);
}

/// Maybe preempt the current task.
///
/// The scheduler lock must *not* be held.
pub fn maybePreempt(current_task: *kernel.Task) void {
    std.debug.assert(current_task.state == .running);

    if (current_task.preemption_disable_count.load(.monotonic) != 0) {
        current_task.preemption_skipped.store(true, .monotonic);
        return;
    }

    lockScheduler(current_task);
    defer unlockScheduler(current_task);

    current_task.preemption_skipped.store(false, .monotonic);

    if (globals.ready_to_run.isEmpty()) return;

    yield(current_task, .requeue);
}

/// Yields the current task.
///
/// Must be called with the scheduler lock held.
pub fn yield(current_task: *kernel.Task, comptime mode: enum { requeue, drop }) void {
    std.debug.assert(globals.lock.isLockedBy(current_task.state.running.id));

    std.debug.assert(current_task.preemption_disable_count.load(.monotonic) == 0);
    std.debug.assert(current_task.preemption_skipped.load(.monotonic) == false);

    const new_task_node = globals.ready_to_run.pop() orelse {
        switch (mode) {
            .requeue => return, // no tasks to run
            .drop => {
                std.debug.assert(!current_task.is_idle_task); // drop during idle

                log.debug("dropping {}", .{current_task});

                switchToIdle(current_task, .dropped);
                core.panic("idle returned", null);
            },
        }
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(new_task.state == .ready);

    if (current_task.is_idle_task) {
        switchToTaskFromIdle(current_task, new_task);
        core.panic("idle returned", null);
    }

    std.debug.assert(current_task != new_task);

    const current_task_new_state = blk: switch (mode) {
        .requeue => {
            log.debug("yielding {}", .{current_task});
            // can't call `queueTask` here because the `current_task.state` is not yet set to `.ready`
            globals.ready_to_run.push(&current_task.next_task_node);
            break :blk .ready;
        },
        .drop => {
            log.debug("dropping {}", .{current_task});
            break :blk .dropped;
        },
    };

    switchToTaskFromTask(current_task, new_task, current_task_new_state);
}

/// Blocks the currently running task.
///
/// The `spinlock` is released by this function, the caller is responsible for acquiring it again if necessary.
///
/// This function must be called with the scheduler lock held.
pub fn block(current_task: *kernel.Task, spinlock: *kernel.sync.TicketSpinLock) void {
    const executor = current_task.state.running;
    std.debug.assert(globals.lock.isLockedBy(executor.id));

    std.debug.assert(!current_task.is_idle_task); // block during idle

    log.debug("blocking {}", .{current_task});

    const new_task_node = globals.ready_to_run.pop() orelse {
        switchToIdleWithLock(current_task, spinlock, .blocked);
        return;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(current_task != new_task);
    std.debug.assert(new_task.state == .ready);

    switchToTaskFromTaskWithLock(current_task, new_task, spinlock, .blocked);
}

fn switchToIdle(current_task: *kernel.Task, current_task_new_state: kernel.Task.State) void {
    std.debug.assert(!current_task.is_idle_task);
    const executor = current_task.state.running;

    kernel.arch.scheduling.prepareForJumpToIdleFromTask(executor, current_task);

    current_task.state = current_task_new_state;

    executor.idle_task.state = .{ .running = executor };
    executor.current_task = &executor.idle_task;

    kernel.arch.scheduling.callOneArgs(
        current_task,
        executor.idle_task.stack,
        &executor.idle_task,
        idle,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => core.panic("insufficent space on the idle task stack", null),
        }
    };
}

fn switchToIdleWithLock(
    current_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
    current_task_new_state: kernel.Task.State,
) void {
    const static = struct {
        fn idleEntryWithLock(
            inner_spinlock: *kernel.sync.TicketSpinLock,
            idle_task: *kernel.Task,
        ) callconv(.C) noreturn {
            std.debug.assert(idle_task.is_idle_task);

            inner_spinlock.unsafeUnlock();

            idle(idle_task);
            core.panic("idle returned", null);
        }
    };

    std.debug.assert(!current_task.is_idle_task);
    const executor = current_task.state.running;

    kernel.arch.scheduling.prepareForJumpToIdleFromTask(executor, current_task);

    current_task.state = current_task_new_state;

    executor.idle_task.state = .{ .running = executor };
    executor.current_task = &executor.idle_task;

    kernel.arch.scheduling.callTwoArgs(
        current_task,
        executor.idle_task.stack,
        spinlock,
        &executor.idle_task,
        static.idleEntryWithLock,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => core.panic("insufficent space on the idle task stack", null),
        }
    };
}

fn switchToTaskFromIdle(current_task: *kernel.Task, new_task: *kernel.Task) void {
    std.debug.assert(current_task.is_idle_task);

    log.debug("switching to {} from idle", .{new_task});

    std.debug.assert(new_task.next_task_node.next == null);

    const executor = current_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromIdle(executor, new_task);

    new_task.state = .{ .running = executor };
    executor.current_task = new_task;
    executor.idle_task.state = .ready;

    kernel.arch.scheduling.jumpToTaskFromIdle(new_task);
    core.panic("task returned", null);
}

fn switchToTaskFromTask(current_task: *kernel.Task, new_task: *kernel.Task, current_task_new_state: kernel.Task.State) void {
    std.debug.assert(!current_task.is_idle_task);
    std.debug.assert(!new_task.is_idle_task);

    log.debug("switching to {} from {}", .{ new_task, current_task });

    std.debug.assert(new_task.next_task_node.next == null);

    const executor = current_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(executor, current_task, new_task);

    current_task.state = current_task_new_state;

    new_task.state = .{ .running = executor };
    executor.current_task = new_task;

    kernel.arch.scheduling.jumpToTaskFromTask(current_task, new_task);
}

fn switchToTaskFromTaskWithLock(
    current_task: *kernel.Task,
    new_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
    current_task_new_state: kernel.Task.State,
) void {
    const static = struct {
        fn switchToTaskWithLock(
            inner_spinlock: *kernel.sync.TicketSpinLock,
            new_task_inner: *kernel.Task,
        ) callconv(.C) noreturn {
            inner_spinlock.unlock(new_task_inner);

            kernel.arch.scheduling.jumpToTaskFromIdle(new_task_inner);
            core.panic("task returned", null);
        }
    };

    std.debug.assert(!current_task.is_idle_task);
    std.debug.assert(!new_task.is_idle_task);

    log.debug("switching to {} from {} with a lock", .{ new_task, current_task });

    std.debug.assert(new_task.next_task_node.next == null);

    const executor = current_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(executor, current_task, new_task);

    current_task.state = current_task_new_state;

    new_task.state = .{ .running = executor };
    executor.current_task = new_task;

    kernel.arch.scheduling.callTwoArgs(
        current_task,
        executor.idle_task.stack,
        spinlock,
        new_task,
        static.switchToTaskWithLock,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => core.panic("insufficent space on the idle task stack", null),
        }
    };
}

pub fn lockScheduler(current_task: *kernel.Task) void {
    globals.lock.lock(current_task);
}

pub fn unlockScheduler(current_task: *kernel.Task) void {
    globals.lock.unlock(current_task);
}

fn idle(current_task: *kernel.Task) callconv(.c) noreturn {
    globals.lock.unlock(current_task);

    log.debug("entering idle", .{});

    while (true) {
        {
            lockScheduler(current_task);
            defer unlockScheduler(current_task);

            if (!globals.ready_to_run.isEmpty()) {
                yield(current_task, .requeue);
            }
        }

        kernel.arch.halt();
    }
}

const globals = struct {
    var lock: SchedulerSpinLock = .{};
    var ready_to_run: containers.SinglyLinkedFIFO = .empty;
};

/// A ticket spinlock similar to `kernel.sync.TicketSpinLock`, but does not disable preemption.
const SchedulerSpinLock = struct {
    current: std.atomic.Value(u32) = .init(0),
    ticket: std.atomic.Value(u32) = .init(0),
    holding_executor: std.atomic.Value(kernel.Executor.Id) = .init(.none),

    fn lock(self: *SchedulerSpinLock, current_task: *kernel.Task) void {
        current_task.incrementInterruptDisable();

        const executor = current_task.state.running;
        std.debug.assert(!self.isLockedBy(executor.id)); // recursive locks are not supported

        const ticket = self.ticket.fetchAdd(1, .acq_rel);
        while (self.current.load(.monotonic) != ticket) {
            kernel.arch.spinLoopHint();
        }
        self.holding_executor.store(executor.id, .release);
    }

    fn unlock(self: *SchedulerSpinLock, current_task: *kernel.Task) void {
        const executor = current_task.state.running;
        std.debug.assert(self.holding_executor.load(.acquire) == executor.id);

        self.holding_executor.store(.none, .release);
        _ = self.current.fetchAdd(1, .acq_rel);

        current_task.decrementInterruptDisable();
    }

    /// Returns true if the spinlock is locked by the given executor.
    fn isLockedBy(self: *const SchedulerSpinLock, executor_id: kernel.Executor.Id) bool {
        return self.holding_executor.load(.acquire) == executor_id;
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");
const log = kernel.debug.log.scoped(.scheduler);

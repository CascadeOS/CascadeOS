// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const log = cascade.debug.log.scoped(.scheduler);

/// Queues a task to be run by the scheduler.
///
/// Must be called with the scheduler lock held.
pub fn queueTask(current_task: *cascade.Task, task: *cascade.Task) void {
    if (core.is_debug) {
        std.debug.assert(!task.is_scheduler_task); // cannot queue a scheduler task
        assertSchedulerLocked(current_task);
        std.debug.assert(task.state == .ready);
    }

    globals.ready_to_run.append(&task.next_task_node);
}

/// Maybe preempt the current task.
///
/// The scheduler lock must *not* be held.
pub fn maybePreempt(current_task: *cascade.Task) void {
    // TODO: do more than just preempt everytime

    if (core.is_debug) {
        assertSchedulerNotLocked(current_task);
        std.debug.assert(current_task.context.spinlocks_held == 0);
        std.debug.assert(current_task.state == .running);
    }

    lockScheduler(current_task);
    defer unlockScheduler(current_task);

    if (globals.ready_to_run.isEmpty()) return;

    log.verbose(current_task, "preempting {f}", .{current_task});

    yield(current_task);
}

/// Yields the current task.
///
/// Must be called with the scheduler lock held.
pub fn yield(current_task: *cascade.Task) void {
    if (core.is_debug) {
        assertSchedulerLocked(current_task);
        std.debug.assert(current_task.context.spinlocks_held == 1); // only the scheduler lock is held
    }

    const new_task_node = globals.ready_to_run.pop() orelse return; // no tasks to run
    const new_task = cascade.Task.fromNode(new_task_node);
    if (core.is_debug) {
        std.debug.assert(!new_task.is_scheduler_task);
        std.debug.assert(new_task.state == .ready);
    }

    if (core.is_debug) std.debug.assert(current_task.state == .running);

    if (current_task.is_scheduler_task) {
        log.verbose(current_task, "switching from idle to {f}", .{new_task});
        switchToTaskFromIdleYield(current_task, new_task);
        unreachable;
    }

    if (core.is_debug) std.debug.assert(current_task != new_task);

    log.verbose(current_task, "switching from {f} to {f}", .{ current_task, new_task });

    globals.ready_to_run.append(&current_task.next_task_node);

    switchToTaskFromTaskYield(current_task, new_task);
}

pub const DeferredAction = struct {
    /// The action to perform after the current task has been switched away from.
    ///
    /// This action will be called while executing as the scheduler task with the scheduler lock held which must not be
    /// unlocked by the action.
    ///
    /// It is the responsibility of the action to set the state of the old task to the correct value.
    action: Action,

    arg: usize,

    pub const Action = *const fn (
        scheduler_task: *cascade.Task,
        old_task: *cascade.Task,
        arg: usize,
    ) void;
};

/// Drops the current task out of the scheduler.
///
/// Intended to be used when blocking or dropping a task.
///
/// The provided `DeferredAction` will be executed after the task has been switched away from.
///
/// Must be called with the scheduler lock held.
pub fn drop(current_task: *cascade.Task, deferred_action: DeferredAction) void {
    if (core.is_debug) {
        std.debug.assert(!current_task.is_scheduler_task); // scheduler task cannot be dropped
        assertSchedulerLocked(current_task);
        std.debug.assert(current_task.state == .running);
    }

    const new_task_node = globals.ready_to_run.pop() orelse {
        log.verbose(current_task, "switching from {f} to idle with a deferred action", .{current_task});
        switchToIdleDeferredAction(current_task, deferred_action);
        return;
    };

    const new_task = cascade.Task.fromNode(new_task_node);
    if (core.is_debug) {
        std.debug.assert(!new_task.is_scheduler_task);
        std.debug.assert(current_task != new_task);
        std.debug.assert(new_task.context.scheduler_locked);
        std.debug.assert(new_task.context.spinlocks_held == 1); // only the scheduler lock is held
        std.debug.assert(new_task.state == .ready);
    }

    log.verbose(current_task, "switching from {f} to {f} with a deferred action", .{ current_task, new_task });

    switchToTaskFromTaskDeferredAction(current_task, new_task, deferred_action);
}

fn switchToIdleDeferredAction(
    current_task: *cascade.Task,
    deferred_action: DeferredAction,
) void {
    const static = struct {
        fn idleEntryDeferredAction(
            scheduler_task_addr: usize,
            old_task_addr: usize,
            action_addr: usize,
            action_arg: usize,
        ) callconv(.c) noreturn {
            const scheduler_task: *cascade.Task = @ptrFromInt(scheduler_task_addr);

            const action: DeferredAction.Action = @ptrFromInt(action_addr);
            action(
                scheduler_task,
                @ptrFromInt(old_task_addr),
                action_arg,
            );
            if (core.is_debug) {
                assertSchedulerLocked(scheduler_task);
                std.debug.assert(scheduler_task.context.interrupt_disable_count == 1);
                std.debug.assert(scheduler_task.context.spinlocks_held == 1);
            }

            idle(scheduler_task);
            @panic("idle returned");
        }
    };

    const old_task = current_task;

    const executor = current_task.context.executor.?;
    const scheduler_task = &executor.scheduler_task;
    if (core.is_debug) std.debug.assert(scheduler_task.state == .ready);

    beforeSwitchTask(executor, old_task, scheduler_task);

    scheduler_task.state = .{ .running = executor };
    scheduler_task.context.executor = executor;
    executor.current_task = scheduler_task;

    arch.scheduling.callFourArgs(
        old_task,
        scheduler_task.stack,

        @intFromPtr(scheduler_task),
        @intFromPtr(old_task),
        @intFromPtr(deferred_action.action),
        deferred_action.arg,

        static.idleEntryDeferredAction,
    ) catch |err| {
        switch (err) {
            error.StackOverflow => @panic("insufficent space on the scheduler task stack"),
        }
    };

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.context.executor == old_task.state.running);
}

fn switchToTaskFromIdleYield(current_task: *cascade.Task, new_task: *cascade.Task) void {
    const executor = current_task.context.executor.?;
    const scheduler_task = current_task;
    if (core.is_debug) std.debug.assert(&executor.scheduler_task == scheduler_task);

    beforeSwitchTask(executor, scheduler_task, new_task);

    new_task.state = .{ .running = executor };
    new_task.context.executor = executor;
    executor.current_task = new_task;

    scheduler_task.state = .ready;

    if (core.is_debug) std.debug.assert(
        switch (scheduler_task.context.interrupt_disable_count) {
            1, 2 => true, // either we are here due to an explicit yield (1) or due to preemption by an interrupt (2)
            else => false,
        },
    );

    // we are abadoning the current scheduler tasks call stack, which means the interrupt increment that would have
    // happened if we are here due to preemption by an interrupt will not be decremented normally, so we set it to 1
    // which is the value is is expected to have upon entry to idle
    scheduler_task.context.interrupt_disable_count = 1;

    arch.scheduling.switchTask(null, new_task);
    @panic("task returned");
}

fn switchToTaskFromTaskYield(
    current_task: *cascade.Task,
    new_task: *cascade.Task,
) void {
    const executor = current_task.context.executor.?;
    const old_task = current_task;

    beforeSwitchTask(executor, old_task, new_task);

    new_task.state = .{ .running = executor };
    new_task.context.executor = executor;
    executor.current_task = new_task;

    old_task.state = .ready;

    arch.scheduling.switchTask(old_task, new_task);

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.context.executor == old_task.state.running);
}

fn switchToTaskFromTaskDeferredAction(
    current_task: *cascade.Task,
    new_task: *cascade.Task,
    deferred_action: DeferredAction,
) void {
    const static = struct {
        fn switchToTaskDeferredAction(
            old_task_addr: usize,
            new_task_addr: usize,
            action_addr: usize,
            action_arg: usize,
        ) callconv(.c) noreturn {
            const inner_old_task: *cascade.Task = @ptrFromInt(old_task_addr);
            const inner_new_task: *cascade.Task = @ptrFromInt(new_task_addr);

            const executor = inner_old_task.context.executor.?;

            const scheduler_task = &executor.scheduler_task;

            const action: DeferredAction.Action = @ptrFromInt(action_addr);
            action(
                scheduler_task,
                inner_old_task,
                action_arg,
            );
            if (core.is_debug) {
                assertSchedulerLocked(scheduler_task);
                std.debug.assert(scheduler_task.context.interrupt_disable_count == 1);
                std.debug.assert(scheduler_task.context.spinlocks_held == 1);
            }

            inner_new_task.state = .{ .running = executor };
            inner_new_task.context.executor = executor;
            executor.current_task = inner_new_task;

            scheduler_task.state = .ready;

            arch.scheduling.switchTask(null, inner_new_task);
            @panic("task returned");
        }
    };

    const executor = current_task.context.executor.?;
    const old_task = current_task;

    beforeSwitchTask(executor, old_task, new_task);

    const scheduler_task = &executor.scheduler_task;

    scheduler_task.state = .{ .running = executor };
    scheduler_task.context.executor = executor;
    executor.current_task = scheduler_task;

    arch.scheduling.callFourArgs(
        old_task,
        scheduler_task.stack,

        @intFromPtr(old_task),
        @intFromPtr(new_task),
        @intFromPtr(deferred_action.action),
        deferred_action.arg,

        static.switchToTaskDeferredAction,
    ) catch |err| {
        switch (err) {
            error.StackOverflow => @panic("insufficent space on the scheduler task stack"),
        }
    };

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.context.executor == old_task.state.running);
}

pub fn lockScheduler(current_task: *cascade.Task) void {
    globals.lock.lock(current_task);
    current_task.context.scheduler_locked = true;
}

pub fn unlockScheduler(current_task: *cascade.Task) void {
    current_task.context.scheduler_locked = false;
    globals.lock.unlock(current_task);
}

/// Asserts that the scheduler lock is held by the current task.
pub inline fn assertSchedulerLocked(current_task: *cascade.Task) void {
    std.debug.assert(current_task.context.scheduler_locked);
    std.debug.assert(globals.lock.isLockedByCurrent(current_task));
}

/// Asserts that the scheduler lock is not held by the current task.
pub inline fn assertSchedulerNotLocked(current_task: *cascade.Task) void {
    std.debug.assert(!current_task.context.scheduler_locked);
    std.debug.assert(!globals.lock.isLockedByCurrent(current_task));
}

fn beforeSwitchTask(
    executor: *cascade.Executor,
    old_task: *cascade.Task,
    new_task: *cascade.Task,
) void {
    arch.scheduling.beforeSwitchTask(executor, old_task, new_task);

    if (old_task.context.enable_access_to_user_memory_count != new_task.context.enable_access_to_user_memory_count) {
        @branchHint(.unlikely); // we expect both to be 0 most of the time
        if (new_task.context.enable_access_to_user_memory_count == 0) {
            @branchHint(.likely);
            arch.paging.disableAccessToUserMemory();
        } else {
            arch.paging.enableAccessToUserMemory();
        }
    }

    switch (old_task.environment) {
        .kernel => switch (new_task.environment) {
            .kernel => {},
            .user => |process| process.address_space.page_table.load(),
        },
        .user => |old_process| switch (new_task.environment) {
            .kernel => cascade.mem.globals.core_page_table.load(),
            .user => |new_process| if (old_process != new_process) new_process.address_space.page_table.load(),
        },
    }
}

// Called directly by assembly code in `arch.scheduling.prepareTaskForScheduling`, so the signature must match.
pub fn taskEntry(
    current_task: *cascade.Task,
    /// must be a function compatible with `arch.scheduling.TaskFunction`
    target_function_addr: *const anyopaque,
    task_arg1: usize,
    task_arg2: usize,
) callconv(.c) noreturn {
    unlockScheduler(current_task);

    const func: arch.scheduling.TaskFunction = @ptrCast(target_function_addr);
    func(current_task, task_arg1, task_arg2) catch |err| {
        std.debug.panic("unhandled error: {t}", .{err});
    };

    lockScheduler(current_task);
    current_task.context.drop();
    unreachable;
}

fn idle(current_task: *cascade.Task) callconv(.c) noreturn {
    if (core.is_debug) {
        std.debug.assert(current_task.context.scheduler_locked);
        std.debug.assert(current_task.context.interrupt_disable_count == 1);
        std.debug.assert(current_task.context.spinlocks_held == 1);
        std.debug.assert(!arch.interrupts.areEnabled());
    }

    log.verbose(current_task, "entering idle", .{});

    while (true) {
        // the scheduler is locked here

        if (!globals.ready_to_run.isEmpty()) {
            yield(current_task);
        }

        unlockScheduler(current_task);

        arch.halt();

        lockScheduler(current_task);
    }
}

const globals = struct {
    var lock: cascade.sync.TicketSpinLock = .{};
    var ready_to_run: core.containers.FIFO = .{};
};

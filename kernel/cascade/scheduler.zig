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
pub fn queueTask(context: *cascade.Context, task: *cascade.Task) void {
    if (core.is_debug) {
        std.debug.assert(!isSchedulerTask(task)); // cannot queue a scheduler task
        assertSchedulerLocked(context);
        std.debug.assert(task.state == .ready);
    }

    globals.ready_to_run.append(&task.next_task_node);
}

/// Maybe preempt the current task.
///
/// The scheduler lock must *not* be held.
pub fn maybePreempt(context: *cascade.Context) void {
    // TODO: do more than just preempt everytime

    const current_task = context.task();
    if (core.is_debug) {
        assertSchedulerNotLocked(context);
        std.debug.assert(context.spinlocks_held == 0);
        std.debug.assert(current_task.state == .running);
    }

    lockScheduler(context);
    defer unlockScheduler(context);

    if (globals.ready_to_run.isEmpty()) return;

    log.verbose(context, "preempting {f}", .{current_task});

    yield(context);
}

/// Yields the current task.
///
/// Must be called with the scheduler lock held.
pub fn yield(context: *cascade.Context) void {
    if (core.is_debug) {
        assertSchedulerLocked(context);
        std.debug.assert(context.spinlocks_held == 1); // only the scheduler lock is held
    }

    const new_task_node = globals.ready_to_run.pop() orelse return; // no tasks to run
    const new_task = cascade.Task.fromNode(new_task_node);
    if (core.is_debug) {
        std.debug.assert(!isSchedulerTask(new_task));
        std.debug.assert(new_task.state == .ready);
    }

    const current_task = context.task();
    if (core.is_debug) std.debug.assert(current_task.state == .running);

    if (isSchedulerTask(current_task)) {
        log.verbose(context, "switching from idle to {f}", .{new_task});
        switchToTaskFromIdleYield(context, new_task);
        unreachable;
    }

    if (core.is_debug) std.debug.assert(current_task != new_task);

    log.verbose(context, "switching from {f} to {f}", .{ current_task, new_task });

    globals.ready_to_run.append(&current_task.next_task_node);

    switchToTaskFromTaskYield(context, new_task);
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
        new_context: *cascade.Context,
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
pub fn drop(context: *cascade.Context, deferred_action: DeferredAction) void {
    const current_task = context.task();
    if (core.is_debug) {
        std.debug.assert(!isSchedulerTask(current_task)); // scheduler task cannot be dropped
        assertSchedulerLocked(context);
        std.debug.assert(current_task.state == .running);
    }

    const new_task_node = globals.ready_to_run.pop() orelse {
        log.verbose(context, "switching from {f} to idle with a deferred action", .{current_task});
        switchToIdleDeferredAction(context, deferred_action);
        return;
    };

    const new_task = cascade.Task.fromNode(new_task_node);
    if (core.is_debug) {
        std.debug.assert(!isSchedulerTask(new_task));
        std.debug.assert(current_task != new_task);
        std.debug.assert(new_task.context.scheduler_locked);
        std.debug.assert(new_task.context.spinlocks_held == 1); // only the scheduler lock is held
        std.debug.assert(new_task.state == .ready);
    }

    log.verbose(context, "switching from {f} to {f} with a deferred action", .{ current_task, new_task });

    switchToTaskFromTaskDeferredAction(context, new_task, deferred_action);
}

fn switchToIdleDeferredAction(
    context: *cascade.Context,
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
            const inner_context = &scheduler_task.context;

            const action: DeferredAction.Action = @ptrFromInt(action_addr);
            action(
                inner_context,
                @ptrFromInt(old_task_addr),
                action_arg,
            );
            if (core.is_debug) {
                assertSchedulerLocked(inner_context);
                std.debug.assert(inner_context.interrupt_disable_count == 1);
                std.debug.assert(inner_context.spinlocks_held == 1);
            }

            idle(inner_context);
            @panic("idle returned");
        }
    };

    const old_task = context.task();

    const current_executor = context.executor.?;
    const scheduler_task = &current_executor.scheduler_task;
    if (core.is_debug) std.debug.assert(scheduler_task.state == .ready);

    arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, scheduler_task);

    scheduler_task.state = .{ .running = current_executor };
    scheduler_task.context.executor = current_executor;
    current_executor.current_task = scheduler_task;

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

fn switchToTaskFromIdleYield(context: *cascade.Context, new_task: *cascade.Task) void {
    const executor = context.executor.?;
    const scheduler_task = context.task();
    if (core.is_debug) std.debug.assert(&executor.scheduler_task == scheduler_task);

    arch.scheduling.prepareForJumpToTaskFromTask(executor, scheduler_task, new_task);

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

    arch.scheduling.jumpToTask(new_task);
    @panic("task returned");
}

fn switchToTaskFromTaskYield(
    context: *cascade.Context,
    new_task: *cascade.Task,
) void {
    const current_executor = context.executor.?;
    const old_task = context.task();

    arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, new_task);

    new_task.state = .{ .running = current_executor };
    new_task.context.executor = current_executor;
    current_executor.current_task = new_task;

    old_task.state = .ready;

    arch.scheduling.jumpToTaskFromTask(old_task, new_task);

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.context.executor == old_task.state.running);
}

fn switchToTaskFromTaskDeferredAction(
    context: *cascade.Context,
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

            const current_executor = inner_old_task.context.executor.?;

            const scheduler_task = &current_executor.scheduler_task;
            const scheduler_task_context = &scheduler_task.context;

            const action: DeferredAction.Action = @ptrFromInt(action_addr);
            action(
                scheduler_task_context,
                inner_old_task,
                action_arg,
            );
            if (core.is_debug) {
                assertSchedulerLocked(scheduler_task_context);
                std.debug.assert(scheduler_task_context.interrupt_disable_count == 1);
                std.debug.assert(scheduler_task_context.spinlocks_held == 1);
            }

            inner_new_task.state = .{ .running = current_executor };
            inner_new_task.context.executor = current_executor;
            current_executor.current_task = inner_new_task;

            scheduler_task.state = .ready;

            arch.scheduling.jumpToTask(inner_new_task);
            @panic("task returned");
        }
    };

    const current_executor = context.executor.?;
    const old_task = context.task();

    arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, new_task);

    const scheduler_task = &current_executor.scheduler_task;

    scheduler_task.state = .{ .running = current_executor };
    scheduler_task.context.executor = current_executor;
    current_executor.current_task = scheduler_task;

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

pub fn lockScheduler(context: *cascade.Context) void {
    globals.lock.lock(context);
    context.scheduler_locked = true;
}

pub fn unlockScheduler(context: *cascade.Context) void {
    context.scheduler_locked = false;
    globals.lock.unlock(context);
}

/// Asserts that the scheduler lock is held by the current task.
pub inline fn assertSchedulerLocked(context: *cascade.Context) void {
    std.debug.assert(context.scheduler_locked);
    std.debug.assert(globals.lock.isLockedByCurrent(context));
}

/// Asserts that the scheduler lock is not held by the current task.
pub inline fn assertSchedulerNotLocked(context: *cascade.Context) void {
    std.debug.assert(!context.scheduler_locked);
    std.debug.assert(!globals.lock.isLockedByCurrent(context));
}

pub fn taskEntry(
    context: *cascade.Context,
    /// must be a function compatible with `arch.scheduling.TaskFunction`
    target_function_addr: *const anyopaque,
    task_arg1: usize,
    task_arg2: usize,
) callconv(.c) noreturn {
    unlockScheduler(context);

    const func: arch.scheduling.TaskFunction = @ptrCast(target_function_addr);
    func(context, task_arg1, task_arg2) catch |err| {
        std.debug.panic("unhandled error: {t}", .{err});
    };

    lockScheduler(context);
    context.drop();
    unreachable;
}

fn idle(context: *cascade.Context) callconv(.c) noreturn {
    if (core.is_debug) {
        std.debug.assert(context.scheduler_locked);
        std.debug.assert(context.interrupt_disable_count == 1);
        std.debug.assert(context.spinlocks_held == 1);
        std.debug.assert(!arch.interrupts.areEnabled());
    }

    log.verbose(context, "entering idle", .{});

    while (true) {
        // the scheduler is locked here

        if (!globals.ready_to_run.isEmpty()) {
            yield(context);
        }

        unlockScheduler(context);

        arch.halt();

        lockScheduler(context);
    }
}

fn isSchedulerTask(task: *cascade.Task) bool {
    return switch (task.environment) {
        .kernel => |kernel_task_type| kernel_task_type == .scheduler,
        .user => false,
    };
}

const globals = struct {
    var lock: cascade.sync.TicketSpinLock = .{};
    var ready_to_run: core.containers.FIFO = .{};
};

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be run by the scheduler.
///
/// Must be called with the scheduler lock held.
pub fn queueTask(context: *kernel.Task.Context, task: *kernel.Task) void {
    if (core.is_debug) {
        std.debug.assert(context.scheduler_locked);
        std.debug.assert(isLockedByCurrent(context));
        std.debug.assert(task.state == .ready);
        std.debug.assert(!isSchedulerTask(task)); // cannot queue a scheduler task
    }

    globals.ready_to_run.append(&task.next_task_node);
}

/// Maybe preempt the current task.
///
/// The scheduler lock must *not* be held.
pub fn maybePreempt(context: *kernel.Task.Context) void {
    // TODO: do more than just preempt everytime

    if (core.is_debug) {
        std.debug.assert(context.task().state == .running);
        std.debug.assert(context.spinlocks_held == 0);
        std.debug.assert(!context.scheduler_locked);
    }

    lockScheduler(context);
    defer unlockScheduler(context);

    if (globals.ready_to_run.isEmpty()) return;

    log.verbose(context, "preempting {f}", .{context.task()});

    yield(context);
}

/// Yields the current task.
///
/// Must be called with the scheduler lock held.
pub fn yield(context: *kernel.Task.Context) void {
    if (core.is_debug) {
        std.debug.assert(context.scheduler_locked);
        std.debug.assert(isLockedByCurrent(context));
        std.debug.assert(context.spinlocks_held == 1); // only the scheduler lock is held
    }

    const new_task_node = globals.ready_to_run.pop() orelse
        return; // no tasks to run

    const new_task = kernel.Task.fromNode(new_task_node);
    if (core.is_debug) {
        std.debug.assert(new_task.state == .ready);
    }

    const current_task = context.task();

    if (isSchedulerTask(current_task)) {
        log.verbose(context, "leaving idle", .{});

        switchToTaskFromIdleYield(context, new_task);
        @panic("idle returned");
    }

    if (core.is_debug) {
        std.debug.assert(current_task != new_task);
    }

    log.verbose(context, "yielding {f}", .{current_task});

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
        new_context: *kernel.Task.Context,
        old_task: *kernel.Task,
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
pub fn drop(context: *kernel.Task.Context, deferred_action: DeferredAction) void {
    if (core.is_debug) {
        std.debug.assert(!isSchedulerTask(context.task())); // drop by the scheduler task

        std.debug.assert(context.scheduler_locked);
        std.debug.assert(isLockedByCurrent(context));
        std.debug.assert(context.spinlocks_held >= 1);
        std.debug.assert(context.interrupt_disable_count >= 1);
    }

    const new_task_node = globals.ready_to_run.pop() orelse {
        switchToIdleDeferredAction(context, deferred_action);
        return;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    if (core.is_debug) {
        std.debug.assert(context.task() != new_task);
        std.debug.assert(new_task.state == .ready);
    }

    switchToTaskFromTaskDeferredAction(context, new_task, deferred_action);
}

fn switchToIdleDeferredAction(
    context: *kernel.Task.Context,
    deferred_action: DeferredAction,
) void {
    const static = struct {
        fn idleEntryDeferredAction(
            scheduler_task_addr: usize,
            old_task_addr: usize,
            action_addr: usize,
            action_arg: usize,
        ) callconv(.c) noreturn {
            const scheduler_task: *kernel.Task = @ptrFromInt(scheduler_task_addr);
            const inner_context = &scheduler_task.context;

            const action: DeferredAction.Action = @ptrFromInt(action_addr);
            action(
                inner_context,
                @ptrFromInt(old_task_addr),
                action_arg,
            );
            if (core.is_debug) {
                std.debug.assert(inner_context.interrupt_disable_count == 1);
                std.debug.assert(inner_context.spinlocks_held == 1);
            }

            unlockScheduler(inner_context);
            idle(inner_context);
            @panic("idle returned");
        }
    };

    const old_task = context.task();

    if (core.is_debug) {
        std.debug.assert(old_task.state == .running);
        std.debug.assert(!isSchedulerTask(old_task));
    }

    log.verbose(context, "switching from {f} to idle with a deferred action", .{old_task});

    const current_executor = context.executor.?;
    if (core.is_debug) {
        std.debug.assert(current_executor.scheduler_task.state == .ready);
    }

    const scheduler_task = &current_executor.scheduler_task;

    arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, scheduler_task);

    scheduler_task.state = .{ .running = current_executor };
    scheduler_task.context.executor = current_executor;
    scheduler_task.context.spinlocks_held = 1;
    scheduler_task.context.interrupt_disable_count = 1;
    scheduler_task.context.scheduler_locked = true;
    current_executor.current_task = scheduler_task;

    old_task.context.executor = null;

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

    old_task.context.executor = old_task.state.running;
}

fn switchToTaskFromIdleYield(context: *kernel.Task.Context, new_task: *kernel.Task) void {
    const current_task = context.task();

    if (core.is_debug) {
        std.debug.assert(context.spinlocks_held == 1); // only the scheduler lock is held
        std.debug.assert(context.scheduler_locked);
        std.debug.assert(isSchedulerTask(current_task));
        std.debug.assert(new_task.next_task_node.next == null);
    }

    log.verbose(context, "switching from idle to {f}", .{new_task});

    const executor = context.executor.?;
    if (core.is_debug) {
        std.debug.assert(&executor.scheduler_task == current_task);
    }

    arch.scheduling.prepareForJumpToTaskFromTask(executor, current_task, new_task);

    new_task.state = .{ .running = executor };
    new_task.context.executor = executor;
    executor.current_task = new_task;

    current_task.state = .ready;
    current_task.context.executor = null;

    arch.scheduling.jumpToTask(new_task);
    @panic("task returned");
}

fn switchToTaskFromTaskYield(
    context: *kernel.Task.Context,
    new_task: *kernel.Task,
) void {
    const old_task = context.task();

    if (core.is_debug) {
        std.debug.assert(context.spinlocks_held == 1);
        std.debug.assert(context.scheduler_locked);
        std.debug.assert(new_task.context.scheduler_locked);

        std.debug.assert(old_task.state == .running);
        std.debug.assert(new_task.state == .ready);

        std.debug.assert(!isSchedulerTask(old_task));
        std.debug.assert(!isSchedulerTask(new_task));
        std.debug.assert(new_task.next_task_node.next == null);
    }

    log.verbose(context, "switching from {f} to {f}", .{ old_task, new_task });

    const current_executor = context.executor.?;
    if (core.is_debug) {
        std.debug.assert(current_executor.current_task == old_task);
    }

    arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, new_task);

    new_task.state = .{ .running = current_executor };
    new_task.context.executor = current_executor;
    current_executor.current_task = new_task;

    old_task.state = .ready;
    old_task.context.executor = null;

    arch.scheduling.jumpToTaskFromTask(old_task, new_task);

    old_task.context.executor = old_task.state.running;
}

fn switchToTaskFromTaskDeferredAction(
    context: *kernel.Task.Context,
    new_task: *kernel.Task,
    deferred_action: DeferredAction,
) void {
    const static = struct {
        fn switchToTaskDeferredAction(
            old_task_addr: usize,
            new_task_addr: usize,
            action_addr: usize,
            action_arg: usize,
        ) callconv(.c) noreturn {
            const inner_old_task: *kernel.Task = @ptrFromInt(old_task_addr);
            const inner_new_task: *kernel.Task = @ptrFromInt(new_task_addr);

            const current_executor = inner_old_task.context.executor.?;
            inner_old_task.context.executor = null;

            const scheduler_task = &current_executor.scheduler_task;
            const scheduler_task_context = &scheduler_task.context;

            const action: DeferredAction.Action = @ptrFromInt(action_addr);
            action(
                scheduler_task_context,
                inner_old_task,
                action_arg,
            );
            if (core.is_debug) {
                std.debug.assert(scheduler_task_context.interrupt_disable_count == 1);
                std.debug.assert(scheduler_task_context.spinlocks_held == 1);
            }

            inner_new_task.state = .{ .running = current_executor };
            inner_new_task.context.executor = current_executor;
            current_executor.current_task = inner_new_task;

            scheduler_task.state = .ready;
            scheduler_task.context.executor = null;

            arch.scheduling.jumpToTask(inner_new_task);
            @panic("task returned");
        }
    };

    const old_task = context.task();

    if (core.is_debug) {
        std.debug.assert(context.scheduler_locked);
        std.debug.assert(new_task.context.scheduler_locked);

        std.debug.assert(old_task.state == .running);
        std.debug.assert(new_task.state == .ready);
        std.debug.assert(!isSchedulerTask(old_task));
        std.debug.assert(!isSchedulerTask(new_task));
    }

    log.verbose(context, "switching from {f} to {f} with a deferred action", .{ old_task, new_task });

    const current_executor = context.executor.?;
    if (core.is_debug) {
        std.debug.assert(current_executor.current_task == old_task);
    }

    arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, new_task);

    const scheduler_task = &current_executor.scheduler_task;

    scheduler_task.state = .{ .running = current_executor };
    scheduler_task.context.spinlocks_held = 1;
    scheduler_task.context.interrupt_disable_count = 1;
    scheduler_task.context.scheduler_locked = true;
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

    old_task.context.executor = old_task.state.running;
}

pub fn lockScheduler(context: *kernel.Task.Context) void {
    globals.lock.lock(context);
    context.scheduler_locked = true;
}

pub fn unlockScheduler(context: *kernel.Task.Context) void {
    context.scheduler_locked = false;
    globals.lock.unlock(context);
}

pub fn isLockedByCurrent(context: *kernel.Task.Context) bool {
    return globals.lock.isLockedByCurrent(context);
}

pub fn newTaskEntry(
    context: *kernel.Task.Context,
    /// must be a function compatible with `arch.scheduling.NewTaskFunction`
    target_function_addr: *const anyopaque,
    task_arg1: usize,
    task_arg2: usize,
) callconv(.c) noreturn {
    unlockScheduler(context);

    const func: arch.scheduling.NewTaskFunction = @ptrCast(target_function_addr);
    func(context, task_arg1, task_arg2);
    @panic("task returned to entry point");
}

fn idle(context: *kernel.Task.Context) callconv(.c) noreturn {
    if (core.is_debug) {
        std.debug.assert(!context.scheduler_locked);
        std.debug.assert(context.interrupt_disable_count == 0);
        std.debug.assert(context.spinlocks_held == 0);
        std.debug.assert(arch.interrupts.areEnabled());
    }

    log.verbose(context, "entering idle", .{});

    while (true) {
        {
            lockScheduler(context);
            defer unlockScheduler(context);

            if (!globals.ready_to_run.isEmpty()) {
                yield(context);
            }
        }

        arch.halt();
    }
}

fn isSchedulerTask(task: *kernel.Task) bool {
    return switch (task.environment) {
        .kernel => |kernel_task_type| kernel_task_type == .scheduler,
        .user => false,
    };
}

const globals = struct {
    var lock: kernel.sync.TicketSpinLock = .{};
    var ready_to_run: core.containers.FIFO = .{};
};

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const log = kernel.debug.log.scoped(.scheduler);
const std = @import("std");

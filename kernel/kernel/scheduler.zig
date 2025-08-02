// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be run by the scheduler.
///
/// Must be called with the scheduler lock held.
pub fn queueTask(current_task: *kernel.Task, task: *kernel.Task) void {
    std.debug.assert(isLockedByCurrent(current_task));
    std.debug.assert(task.state == .ready);
    std.debug.assert(!current_task.state.running.isSchedulerTask(task)); // cannot queue a scheduler task

    globals.ready_to_run.append(&task.next_task_node);
}

/// Maybe preempt the current task.
///
/// The scheduler lock must *not* be held.
pub fn maybePreempt(current_task: *kernel.Task) void {
    // TODO: do more than just preempt everytime

    std.debug.assert(current_task.state == .running);
    std.debug.assert(current_task.spinlocks_held == 0);

    lockScheduler(current_task);
    defer unlockScheduler(current_task);

    if (globals.ready_to_run.isEmpty()) return;

    log.verbose("preempting {f}", .{current_task});

    yield(current_task);
}

/// Yields the current task.
///
/// Must be called with the scheduler lock held.
pub fn yield(current_task: *kernel.Task) void {
    std.debug.assert(isLockedByCurrent(current_task));
    std.debug.assert(current_task.spinlocks_held == 1); // only the scheduler lock is held

    const new_task_node = globals.ready_to_run.pop() orelse
        return; // no tasks to run

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(new_task.state == .ready);

    if (current_task.state.running.isSchedulerTask(current_task)) {
        log.verbose("leaving idle", .{});

        switchToTaskFromIdleYield(current_task, new_task);
        @panic("idle returned");
    }

    std.debug.assert(current_task != new_task);

    log.verbose("yielding {f}", .{current_task});

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

    context: ?*anyopaque,

    pub const Action = *const fn (
        new_current_task: *kernel.Task,
        old_task: *kernel.Task,
        context: ?*anyopaque,
    ) void;
};

/// Drops the current task out of the scheduler.
///
/// Intended to be used when blocking or dropping a task.
///
/// The provided `DeferredAction` will be executed after the task has been switched away from.
///
/// Must be called with the scheduler lock held.
pub fn drop(current_task: *kernel.Task, deferred_action: DeferredAction) void {
    std.debug.assert(!current_task.state.running.isSchedulerTask(current_task)); // drop by the scheduler task

    std.debug.assert(isLockedByCurrent(current_task)); // the scheduler lock is held
    std.debug.assert(current_task.spinlocks_held >= 1);
    std.debug.assert(current_task.interrupt_disable_count >= 1);

    const new_task_node = globals.ready_to_run.pop() orelse {
        switchToIdleDeferredAction(current_task, deferred_action);
        return;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(current_task != new_task);
    std.debug.assert(new_task.state == .ready);

    switchToTaskFromTaskDeferredAction(current_task, new_task, deferred_action);
}

fn switchToIdleDeferredAction(
    old_task: *kernel.Task,
    deferred_action: DeferredAction,
) void {
    const static = struct {
        fn idleEntryDeferredAction(
            scheduler_task_addr: usize,
            old_task_addr: usize,
            action_addr: usize,
            action_context_addr: usize,
        ) callconv(.c) noreturn {
            const scheduler_task: *kernel.Task = @ptrFromInt(scheduler_task_addr);

            const action: DeferredAction.Action = @ptrFromInt(action_addr);
            action(
                scheduler_task,
                @ptrFromInt(old_task_addr),
                @ptrFromInt(action_context_addr),
            );
            std.debug.assert(scheduler_task.interrupt_disable_count == 1);
            std.debug.assert(scheduler_task.spinlocks_held == 1);

            globals.lock.unlock(scheduler_task);
            idle(scheduler_task);
            @panic("idle returned");
        }
    };

    std.debug.assert(old_task.state == .running);
    std.debug.assert(!old_task.state.running.isSchedulerTask(old_task));

    log.verbose("switching from {f} to idle with a deferred action", .{old_task});

    const current_executor = old_task.state.running;
    std.debug.assert(current_executor.scheduler_task.state == .ready);

    const scheduler_task = &current_executor.scheduler_task;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, scheduler_task);

    scheduler_task.state = .{ .running = current_executor };
    scheduler_task.spinlocks_held = 1;
    scheduler_task.interrupt_disable_count = 1;
    current_executor.current_task = scheduler_task;

    kernel.arch.scheduling.callFourArgs(
        old_task,
        scheduler_task.stack,

        @intFromPtr(scheduler_task),
        @intFromPtr(old_task),
        @intFromPtr(deferred_action.action),
        @intFromPtr(deferred_action.context),

        static.idleEntryDeferredAction,
    ) catch |err| {
        switch (err) {
            error.StackOverflow => @panic("insufficent space on the scheduler task stack"),
        }
    };
}

fn switchToTaskFromIdleYield(current_task: *kernel.Task, new_task: *kernel.Task) void {
    std.debug.assert(current_task.spinlocks_held == 1); // only the scheduler lock is held
    std.debug.assert(current_task.state.running.isSchedulerTask(current_task));
    std.debug.assert(new_task.next_task_node.next == null);

    log.verbose("switching from idle to {f}", .{new_task});

    const executor = current_task.state.running;
    std.debug.assert(&executor.scheduler_task == current_task);

    const scheduler_task = current_task;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(executor, scheduler_task, new_task);

    new_task.state = .{ .running = executor };
    executor.current_task = new_task;
    scheduler_task.state = .ready;

    kernel.arch.scheduling.jumpToTask(new_task);
    @panic("task returned");
}

fn switchToTaskFromTaskYield(
    old_task: *kernel.Task,
    new_task: *kernel.Task,
) void {
    std.debug.assert(old_task.spinlocks_held == 1); // only the scheduler lock is held
    std.debug.assert(old_task.state == .running);
    std.debug.assert(new_task.state == .ready);
    std.debug.assert(!old_task.state.running.isSchedulerTask(old_task));
    std.debug.assert(!old_task.state.running.isSchedulerTask(new_task));
    std.debug.assert(new_task.next_task_node.next == null);

    log.verbose("switching from {f} to {f}", .{ old_task, new_task });

    const current_executor = old_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, new_task);

    new_task.state = .{ .running = current_executor };
    current_executor.current_task = new_task;

    old_task.state = .ready;

    kernel.arch.scheduling.jumpToTaskFromTask(old_task, new_task);
}

fn switchToTaskFromTaskDeferredAction(
    old_task: *kernel.Task,
    new_task: *kernel.Task,
    deferred_action: DeferredAction,
) void {
    const static = struct {
        fn switchToTaskDeferredAction(
            old_task_addr: usize,
            new_task_addr: usize,
            action_addr: usize,
            action_context_addr: usize,
        ) callconv(.c) noreturn {
            const inner_old_task: *kernel.Task = @ptrFromInt(old_task_addr);
            const inner_new_task: *kernel.Task = @ptrFromInt(new_task_addr);

            const current_executor = inner_old_task.state.running;
            const scheduler_task = &current_executor.scheduler_task;

            const action: DeferredAction.Action = @ptrFromInt(action_addr);
            action(
                scheduler_task,
                inner_old_task,
                @ptrFromInt(action_context_addr),
            );
            std.debug.assert(scheduler_task.interrupt_disable_count == 1);
            std.debug.assert(scheduler_task.spinlocks_held == 1);

            inner_new_task.state = .{ .running = current_executor };
            current_executor.current_task = inner_new_task;
            scheduler_task.state = .ready;

            kernel.arch.scheduling.jumpToTask(inner_new_task);
            @panic("task returned");
        }
    };

    std.debug.assert(old_task.state == .running);
    std.debug.assert(new_task.state == .ready);
    std.debug.assert(!old_task.state.running.isSchedulerTask(old_task));
    std.debug.assert(!old_task.state.running.isSchedulerTask(new_task));

    log.verbose("switching from {f} to {f} with a deferred action", .{ old_task, new_task });

    const current_executor = old_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, new_task);

    const scheduler_task = &current_executor.scheduler_task;

    scheduler_task.state = .{ .running = current_executor };
    scheduler_task.spinlocks_held = 1;
    scheduler_task.interrupt_disable_count = 1;
    current_executor.current_task = scheduler_task;

    kernel.arch.scheduling.callFourArgs(
        old_task,
        current_executor.scheduler_task.stack,

        @intFromPtr(old_task),
        @intFromPtr(new_task),
        @intFromPtr(deferred_action.action),
        @intFromPtr(deferred_action.context),

        static.switchToTaskDeferredAction,
    ) catch |err| {
        switch (err) {
            error.StackOverflow => @panic("insufficent space on the scheduler task stack"),
        }
    };
}

pub fn lockScheduler(current_task: *kernel.Task) void {
    globals.lock.lock(current_task);
}

pub fn unlockScheduler(current_task: *kernel.Task) void {
    globals.lock.unlock(current_task);
}

pub fn isLockedByCurrent(current_task: *kernel.Task) bool {
    return globals.lock.isLockedByCurrent(current_task);
}

pub fn newTaskEntry(
    current_task: *kernel.Task,
    /// must be a function compatible with `kernel.arch.scheduling.NewTaskFunction`
    target_function_addr: *const anyopaque,
    task_arg1: usize,
    task_arg2: usize,
) callconv(.c) noreturn {
    globals.lock.unlock(current_task);

    const func: kernel.arch.scheduling.NewTaskFunction = @ptrCast(target_function_addr);
    func(current_task, task_arg1, task_arg2);
    @panic("task returned to entry point");
}

fn idle(current_task: *kernel.Task) callconv(.c) noreturn {
    std.debug.assert(current_task.interrupt_disable_count == 0);
    std.debug.assert(current_task.spinlocks_held == 0);
    std.debug.assert(kernel.arch.interrupts.areEnabled());

    log.verbose("entering idle", .{});

    while (true) {
        {
            lockScheduler(current_task);
            defer unlockScheduler(current_task);

            if (!globals.ready_to_run.isEmpty()) {
                yield(current_task);
            }
        }

        kernel.arch.halt();
    }
}

const globals = struct {
    var lock: kernel.sync.TicketSpinLock = .{};
    var ready_to_run: core.containers.FIFO = .{};
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.scheduler);

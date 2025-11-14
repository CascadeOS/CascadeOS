// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Process = cascade.Process;
const core = @import("core");

const log = cascade.debug.log.scoped(.scheduler);

/// Queues a task to be run by the scheduler.
///
/// Must be called with the scheduler lock held.
pub fn queueTask(current_task: Task.Current, task: *Task) void {
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
pub fn maybePreempt(current_task: Task.Current) void {
    // TODO: do more than just preempt everytime

    if (core.is_debug) {
        assertSchedulerNotLocked(current_task);
        std.debug.assert(current_task.task.spinlocks_held == 0);
        std.debug.assert(current_task.task.state == .running);
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
pub fn yield(current_task: Task.Current) void {
    if (core.is_debug) {
        assertSchedulerLocked(current_task);
        std.debug.assert(current_task.task.spinlocks_held == 1); // only the scheduler lock is held
    }

    const new_task_node = globals.ready_to_run.pop() orelse return; // no tasks to run
    const new_task: *Task = .fromNode(new_task_node);
    if (core.is_debug) {
        std.debug.assert(!new_task.is_scheduler_task);
        std.debug.assert(new_task.state == .ready);
    }

    if (core.is_debug) std.debug.assert(current_task.task.state == .running);

    if (current_task.task.is_scheduler_task) {
        log.verbose(current_task, "switching from idle to {f}", .{new_task});
        switchToTaskFromIdleYield(current_task, new_task);
        unreachable;
    }

    if (core.is_debug) std.debug.assert(current_task.task != new_task);

    log.verbose(current_task, "switching from {f} to {f}", .{ current_task, new_task });

    globals.ready_to_run.append(&current_task.task.next_task_node);

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
        current_task: Task.Current,
        old_task: *Task,
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
pub fn drop(current_task: Task.Current, deferred_action: DeferredAction) void {
    if (core.is_debug) {
        std.debug.assert(!current_task.task.is_scheduler_task); // scheduler task cannot be dropped
        assertSchedulerLocked(current_task);
        std.debug.assert(current_task.task.state == .running);
    }

    const new_task_node = globals.ready_to_run.pop() orelse {
        log.verbose(current_task, "switching from {f} to idle with a deferred action", .{current_task});
        switchToIdleDeferredAction(current_task, deferred_action);
        return;
    };

    const new_task: *Task = .fromNode(new_task_node);
    if (core.is_debug) {
        std.debug.assert(!new_task.is_scheduler_task);
        std.debug.assert(current_task.task != new_task);
        std.debug.assert(new_task.scheduler_locked);
        std.debug.assert(new_task.spinlocks_held == 1); // only the scheduler lock is held
        std.debug.assert(new_task.state == .ready);
    }

    log.verbose(current_task, "switching from {f} to {f} with a deferred action", .{ current_task, new_task });

    switchToTaskFromTaskDeferredAction(current_task, new_task, deferred_action);
}

fn switchToIdleDeferredAction(
    current_task: Task.Current,
    deferred_action: DeferredAction,
) void {
    const static = struct {
        fn idleEntryDeferredAction(
            scheduler_task: *Task,
            old_task: *Task,
            action: DeferredAction.Action,
            action_arg: usize,
        ) noreturn {
            const inner_current_task: Task.Current = .{ .task = scheduler_task };
            action(inner_current_task, old_task, action_arg);
            if (core.is_debug) {
                assertSchedulerLocked(inner_current_task);
                std.debug.assert(inner_current_task.task.interrupt_disable_count == 1);
                std.debug.assert(inner_current_task.task.spinlocks_held == 1);
            }

            idle(inner_current_task);
            @panic("idle returned");
        }
    };

    const old_task = current_task.task;

    const executor = current_task.knownExecutor();
    const scheduler_task = &executor.scheduler_task;
    if (core.is_debug) std.debug.assert(scheduler_task.state == .ready);

    beforeSwitchTask(current_task, old_task, scheduler_task);

    scheduler_task.state = .{ .running = executor };
    scheduler_task.known_executor = executor;
    executor.current_task = scheduler_task;

    arch.scheduling.call(
        old_task,
        scheduler_task.stack,
        .prepare(
            static.idleEntryDeferredAction,
            .{
                scheduler_task,
                old_task,
                deferred_action.action,
                deferred_action.arg,
            },
        ),
    ) catch |err| {
        switch (err) {
            error.StackOverflow => @panic("insufficent space on the scheduler task stack"),
        }
    };

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.known_executor == old_task.state.running);
}

fn switchToTaskFromIdleYield(current_task: Task.Current, new_task: *Task) void {
    const executor = current_task.knownExecutor();
    const scheduler_task = current_task.task;
    if (core.is_debug) std.debug.assert(&executor.scheduler_task == scheduler_task);

    beforeSwitchTask(current_task, scheduler_task, new_task);

    new_task.state = .{ .running = executor };
    new_task.known_executor = executor;
    executor.current_task = new_task;

    scheduler_task.state = .ready;

    if (core.is_debug) std.debug.assert(
        switch (scheduler_task.interrupt_disable_count) {
            1, 2 => true, // either we are here due to an explicit yield (1) or due to preemption by an interrupt (2)
            else => false,
        },
    );

    // we are abadoning the current scheduler tasks call stack, which means the interrupt increment that would have
    // happened if we are here due to preemption by an interrupt will not be decremented normally, so we set it to 1
    // which is the value is is expected to have upon entry to idle
    scheduler_task.interrupt_disable_count = 1;

    arch.scheduling.switchTask(null, new_task);
    @panic("task returned");
}

fn switchToTaskFromTaskYield(
    current_task: Task.Current,
    new_task: *Task,
) void {
    const executor = current_task.knownExecutor();
    const old_task = current_task.task;

    beforeSwitchTask(current_task, old_task, new_task);

    new_task.state = .{ .running = executor };
    new_task.known_executor = executor;
    executor.current_task = new_task;

    old_task.state = .ready;

    arch.scheduling.switchTask(old_task, new_task);

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.known_executor == old_task.state.running);
}

fn switchToTaskFromTaskDeferredAction(
    current_task: Task.Current,
    new_task: *Task,
    deferred_action: DeferredAction,
) void {
    const static = struct {
        fn switchToTaskDeferredAction(
            inner_old_task: *Task,
            inner_new_task: *Task,
            action: DeferredAction.Action,
            action_arg: usize,
        ) noreturn {
            const executor = inner_old_task.known_executor.?;

            const inner_current_task: Task.Current = .{ .task = &executor.scheduler_task };

            action(
                inner_current_task,
                inner_old_task,
                action_arg,
            );
            if (core.is_debug) {
                assertSchedulerLocked(inner_current_task);
                std.debug.assert(inner_current_task.task.interrupt_disable_count == 1);
                std.debug.assert(inner_current_task.task.spinlocks_held == 1);
            }

            inner_new_task.state = .{ .running = executor };
            inner_new_task.known_executor = executor;
            executor.current_task = inner_new_task;

            inner_current_task.task.state = .ready;

            arch.scheduling.switchTask(null, inner_new_task);
            @panic("task returned");
        }
    };

    const executor = current_task.knownExecutor();
    const old_task = current_task.task;

    beforeSwitchTask(current_task, old_task, new_task);

    const scheduler_task = &executor.scheduler_task;

    scheduler_task.state = .{ .running = executor };
    scheduler_task.known_executor = executor;
    executor.current_task = scheduler_task;

    arch.scheduling.call(
        old_task,
        scheduler_task.stack,
        .prepare(
            static.switchToTaskDeferredAction,
            .{
                old_task,
                new_task,
                deferred_action.action,
                deferred_action.arg,
            },
        ),
    ) catch |err| {
        switch (err) {
            error.StackOverflow => @panic("insufficent space on the scheduler task stack"),
        }
    };

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.known_executor == old_task.state.running);
}

pub fn lockScheduler(current_task: Task.Current) void {
    globals.lock.lock(current_task);
    current_task.task.scheduler_locked = true;
}

pub fn unlockScheduler(current_task: Task.Current) void {
    current_task.task.scheduler_locked = false;
    globals.lock.unlock(current_task);
}

/// Asserts that the scheduler lock is held by the current task.
pub inline fn assertSchedulerLocked(current_task: Task.Current) void {
    std.debug.assert(current_task.task.scheduler_locked);
    std.debug.assert(globals.lock.isLockedByCurrent(current_task));
}

/// Asserts that the scheduler lock is not held by the current task.
pub inline fn assertSchedulerNotLocked(current_task: Task.Current) void {
    std.debug.assert(!current_task.task.scheduler_locked);
    std.debug.assert(!globals.lock.isLockedByCurrent(current_task));
}

fn beforeSwitchTask(
    current_task: Task.Current,
    old_task: *Task,
    new_task: *Task,
) void {
    arch.scheduling.beforeSwitchTask(current_task, old_task, new_task);

    if (old_task.enable_access_to_user_memory_count != new_task.enable_access_to_user_memory_count) {
        @branchHint(.unlikely); // we expect both to be 0 most of the time
        if (new_task.enable_access_to_user_memory_count == 0) {
            @branchHint(.likely);
            arch.paging.disableAccessToUserMemory();
        } else {
            arch.paging.enableAccessToUserMemory();
        }
    }

    switch (old_task.type) {
        .kernel => switch (new_task.type) {
            .kernel => {},
            .user => {
                const new_process: *Process = .fromTask(new_task);
                new_process.address_space.page_table.load(current_task);
            },
        },
        .user => {
            const old_process: *const Process = .fromTask(old_task);
            switch (new_task.type) {
                .kernel => cascade.mem.kernelPageTable().load(current_task),
                .user => {
                    const new_process: *Process = .fromTask(new_task);
                    if (old_process != new_process) new_process.address_space.page_table.load(current_task);
                },
            }
        },
    }
}

fn idle(current_task: Task.Current) callconv(.c) noreturn {
    if (core.is_debug) {
        std.debug.assert(current_task.task.scheduler_locked);
        std.debug.assert(current_task.task.interrupt_disable_count == 1);
        std.debug.assert(current_task.task.spinlocks_held == 1);
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

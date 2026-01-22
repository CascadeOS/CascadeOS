// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const Process = kernel.user.Process;
const core = @import("core");

pub const Scheduler = @import("Scheduler.zig");

const log = kernel.debug.log.scoped(.scheduler);
const SchedulerHandle = @This();

scheduler: *Scheduler,

/// Returns a handle to the scheduler.
///
/// The scheduler is locked by this function, it is the caller's responsibility to call `SchedulerHandle.unlock` when
/// the handle is no longer needed.
///
/// When dropping the task the scheduler handle does not need to be released.
pub fn get() SchedulerHandle {
    const scheduler = &globals.scheduler;
    scheduler.lock();
    return .{ .scheduler = &globals.scheduler };
}

pub const MaybeLocked = struct {
    was_locked: bool,
    scheduler_handle: SchedulerHandle,

    /// Returns a handle to the scheduler.
    ///
    /// Supports the scheduler already being locked. The scheduler will be locked when this function returns.
    ///
    /// It is the caller's responsibility to call `MaybeLocked.unlock` when
    pub fn get() MaybeLocked {
        const scheduler = &globals.scheduler;

        const scheduler_already_locked = Task.Current.get().task.scheduler_locked;

        switch (scheduler_already_locked) {
            true => if (core.is_debug) scheduler.assertLocked(),
            false => scheduler.lock(),
        }

        return .{
            .was_locked = scheduler_already_locked,
            .scheduler_handle = .{ .scheduler = scheduler },
        };
    }

    pub fn unlock(maybe_locked: MaybeLocked) void {
        if (!maybe_locked.was_locked) maybe_locked.scheduler_handle.unlock();
    }
};

pub fn unlock(scheduler_handle: SchedulerHandle) void {
    scheduler_handle.scheduler.unlock();
}

pub fn queueTask(scheduler_handle: SchedulerHandle, task: *Task) void {
    if (core.is_debug) {
        std.debug.assert(!task.is_scheduler_task); // cannot queue a scheduler task
        scheduler_handle.scheduler.assertLocked();
        std.debug.assert(task.state == .ready);
    }

    scheduler_handle.scheduler.queueTask(task);
}

pub fn isEmpty(scheduler_handle: SchedulerHandle) bool {
    if (core.is_debug) scheduler_handle.scheduler.assertLocked();
    return scheduler_handle.scheduler.isEmpty();
}

/// Yields the current task.
pub fn yield(scheduler_handle: SchedulerHandle) void {
    const old_task = Task.Current.get().task;

    if (core.is_debug) {
        scheduler_handle.scheduler.assertLocked();
        std.debug.assert(old_task.spinlocks_held == 1); // only the scheduler lock is held
    }

    const new_task = scheduler_handle.scheduler.getNextTask() orelse return; // no tasks to run

    if (core.is_debug) std.debug.assert(old_task.state == .running);

    if (old_task.is_scheduler_task) {
        log.verbose("switching from idle to {f}", .{new_task});
        switchToTaskFromIdleYield(old_task, new_task);
        unreachable;
    }

    if (core.is_debug) std.debug.assert(old_task != new_task);

    log.verbose("switching from {f} to {f}", .{ old_task, new_task });

    scheduler_handle.switchToTaskFromTaskYield(old_task, new_task);
}

/// Drops the current task out of the scheduler.
///
/// Decrements the reference count of the task to remove the implicit self reference.
pub fn drop(scheduler_handle: SchedulerHandle) noreturn {
    if (core.is_debug) {
        scheduler_handle.scheduler.assertLocked();
        std.debug.assert(Task.Current.get().task.spinlocks_held == 1); // only the scheduler lock is held
    }

    scheduler_handle.dropWithDeferredAction(.{
        .action = struct {
            fn action(old_task: *Task, _: usize) void {
                old_task.state = .{ .dropped = .{} };
                old_task.decrementReferenceCount();
            }
        }.action,
        .arg = undefined,
    });
    @panic("dropped task returned");
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
        old_task: *Task,
        arg: usize,
    ) void;
};

/// Drops the current task out of the scheduler.
///
/// Intended to be used when blocking or dropping a task.
///
/// The provided `DeferredAction` will be executed after the task has been switched away from.
pub fn dropWithDeferredAction(scheduler_handle: SchedulerHandle, deferred_action: DeferredAction) void {
    const old_task = Task.Current.get().task;

    if (core.is_debug) {
        std.debug.assert(!old_task.is_scheduler_task); // scheduler task cannot be dropped
        scheduler_handle.scheduler.assertLocked();
        std.debug.assert(old_task.state == .running);
    }

    const new_task = scheduler_handle.scheduler.getNextTask() orelse {
        log.verbose("switching from {f} to idle with a deferred action", .{old_task});
        switchToIdleDeferredAction(old_task, deferred_action);
        return;
    };
    if (core.is_debug) {
        std.debug.assert(!new_task.is_scheduler_task);
        std.debug.assert(old_task != new_task);
        std.debug.assert(new_task.scheduler_locked);
        std.debug.assert(new_task.spinlocks_held == 1); // only the scheduler lock is held
        std.debug.assert(new_task.state == .ready);
    }

    log.verbose("switching from {f} to {f} with a deferred action", .{ old_task, new_task });

    switchToTaskFromTaskDeferredAction(old_task, new_task, deferred_action);
}

fn switchToIdleDeferredAction(
    old_task: *Task,
    deferred_action: DeferredAction,
) void {
    const static = struct {
        fn idleEntryDeferredAction(
            inner_old_task: *Task,
            action: DeferredAction.Action,
            action_arg: usize,
        ) noreturn {
            action(inner_old_task, action_arg);
            if (core.is_debug) {
                const scheduler_task = Task.Current.get().task;
                std.debug.assert(scheduler_task.is_scheduler_task);
                std.debug.assert(scheduler_task.interrupt_disable_count == 1);
                std.debug.assert(scheduler_task.spinlocks_held == 1);
            }
            idle();
            unreachable;
        }
    };

    const executor = old_task.known_executor.?;
    const scheduler_task = &executor.scheduler_task;
    if (core.is_debug) std.debug.assert(scheduler_task.state == .ready);

    beforeSwitchTask(old_task, scheduler_task);

    scheduler_task.state = .{ .running = executor };
    scheduler_task.known_executor = executor;
    executor.setCurrentTask(scheduler_task);

    arch.scheduling.call(
        old_task,
        &scheduler_task.stack,
        .prepare(
            static.idleEntryDeferredAction,
            .{
                old_task,
                deferred_action.action,
                deferred_action.arg,
            },
        ),
    );

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.known_executor == old_task.state.running);
}

fn switchToTaskFromIdleYield(scheduler_task: *Task, new_task: *Task) void {
    const executor = scheduler_task.known_executor.?;
    if (core.is_debug) std.debug.assert(&executor.scheduler_task == scheduler_task);

    beforeSwitchTask(scheduler_task, new_task);

    new_task.state = .{ .running = executor };
    new_task.known_executor = executor;
    executor.setCurrentTask(new_task);

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

    arch.scheduling.switchTaskNoSave(new_task);
    unreachable;
}

fn switchToTaskFromTaskYield(
    scheduler_handle: SchedulerHandle,
    old_task: *Task,
    new_task: *Task,
) void {
    const executor = old_task.known_executor.?;

    beforeSwitchTask(old_task, new_task);

    new_task.state = .{ .running = executor };
    new_task.known_executor = executor;
    executor.setCurrentTask(new_task);

    old_task.state = .ready;
    scheduler_handle.scheduler.queueTask(old_task);

    arch.scheduling.switchTask(old_task, new_task);

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.known_executor == old_task.state.running);
}

fn switchToTaskFromTaskDeferredAction(
    old_task: *Task,
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
            const scheduler_task = Task.Current.get().task;
            if (core.is_debug) std.debug.assert(scheduler_task.is_scheduler_task);
            const executor = scheduler_task.known_executor.?;

            action(inner_old_task, action_arg);
            if (core.is_debug) {
                std.debug.assert(Task.Current.get().task == scheduler_task);
                std.debug.assert(scheduler_task.interrupt_disable_count == 1);
                std.debug.assert(scheduler_task.spinlocks_held == 1);
            }

            inner_new_task.state = .{ .running = executor };
            inner_new_task.known_executor = executor;
            executor.setCurrentTask(inner_new_task);

            scheduler_task.state = .ready;

            arch.scheduling.switchTaskNoSave(inner_new_task);
            unreachable;
        }
    };

    const executor = old_task.known_executor.?;

    beforeSwitchTask(old_task, new_task);

    const scheduler_task = &executor.scheduler_task;

    scheduler_task.state = .{ .running = executor };
    scheduler_task.known_executor = executor;
    executor.setCurrentTask(scheduler_task);

    arch.scheduling.call(
        old_task,
        &scheduler_task.stack,
        .prepare(
            static.switchToTaskDeferredAction,
            .{
                old_task,
                new_task,
                deferred_action.action,
                deferred_action.arg,
            },
        ),
    );

    // returning to the old task
    if (core.is_debug) std.debug.assert(old_task.known_executor == old_task.state.running);
}

fn beforeSwitchTask(
    old_task: *Task,
    new_task: *Task,
) void {
    const transition: Task.Transition = .from(old_task, new_task);

    switch (transition.type) {
        .kernel_to_kernel => {
            if (core.is_debug) {
                std.debug.assert(transition.old_task.enable_access_to_user_memory_count == 0);
                std.debug.assert(transition.new_task.enable_access_to_user_memory_count == 0);
            }
        },
        .kernel_to_user => {
            if (core.is_debug) {
                std.debug.assert(transition.old_task.enable_access_to_user_memory_count == 0);
            }

            const new_process: *Process = .from(transition.new_task);
            new_process.address_space.page_table.load();

            if (transition.new_task.enable_access_to_user_memory_count != 0) {
                @branchHint(.unlikely); // we expect this to be 0 most of the time
                arch.paging.enableAccessToUserMemory();
            }
        },
        .user_to_kernel => {
            if (core.is_debug) {
                std.debug.assert(transition.new_task.enable_access_to_user_memory_count == 0);
            }

            kernel.mem.kernelPageTable().load();

            if (transition.old_task.enable_access_to_user_memory_count != 0) {
                @branchHint(.unlikely); // we expect this to be 0 most of the time
                arch.paging.disableAccessToUserMemory();
            }
        },
        .user_to_user => {
            const old_process: *const Process = .from(transition.old_task);
            const new_process: *Process = .from(transition.new_task);
            if (old_process != new_process) new_process.address_space.page_table.load();

            if (transition.old_task.enable_access_to_user_memory_count != transition.new_task.enable_access_to_user_memory_count) {
                @branchHint(.unlikely); // we expect both to be 0 most of the time

                if (transition.new_task.enable_access_to_user_memory_count == 0) {
                    arch.paging.disableAccessToUserMemory();
                } else {
                    arch.paging.enableAccessToUserMemory();
                }
            }
        },
    }

    arch.scheduling.beforeSwitchTask(transition);
}

fn idle() callconv(.c) noreturn {
    if (core.is_debug) {
        const scheduler_task = Task.Current.get().task;
        std.debug.assert(scheduler_task.is_scheduler_task);
        std.debug.assert(scheduler_task.scheduler_locked);
        std.debug.assert(scheduler_task.interrupt_disable_count == 1);
        std.debug.assert(scheduler_task.spinlocks_held == 1);
        std.debug.assert(!arch.interrupts.areEnabled());
    }

    globals.scheduler.unlock();

    while (true) {
        {
            const scheduler_handle: Task.SchedulerHandle = .get();
            defer scheduler_handle.unlock();

            scheduler_handle.yield();
        }

        arch.halt();
    }
}

pub const internal = struct {
    pub fn unsafeUnlock() void {
        globals.scheduler.unlock();
    }
};

const globals = struct {
    // TODO: make this per-executor
    var scheduler: Scheduler = .{};
};

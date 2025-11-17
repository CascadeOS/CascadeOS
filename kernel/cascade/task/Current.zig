// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Process = cascade.Process;
const core = @import("core");

const Scheduler = @import("Scheduler.zig");

const log = cascade.debug.log.scoped(.task);

pub const Current = extern struct {
    task: *Task,

    /// Returns the executor that the current task is running on if it is known.
    ///
    /// Asserts that the `known_executor` field is non-null.
    pub fn knownExecutor(current_task: Current) *cascade.Executor {
        return current_task.task.known_executor.?;
    }

    pub fn current() Task.Current {
        // TODO: some architectures can do this without disabling interrupts

        arch.interrupts.disable();

        const executor = arch.getCurrentExecutor();
        const current_task = executor.current_task;
        if (core.is_debug) std.debug.assert(current_task.state.running == executor);

        if (current_task.interrupt_disable_count == 0) arch.interrupts.enable();

        return .{ .task = current_task };
    }

    pub fn incrementInterruptDisable(current_task: Task.Current) void {
        const previous = current_task.task.interrupt_disable_count;

        if (previous == 0) {
            if (core.is_debug) std.debug.assert(arch.interrupts.areEnabled());
            arch.interrupts.disable();
            current_task.task.known_executor = current_task.task.state.running;
        } else if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

        current_task.task.interrupt_disable_count = previous + 1;
    }

    pub fn decrementInterruptDisable(current_task: Task.Current) void {
        if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

        const previous = current_task.task.interrupt_disable_count;
        current_task.task.interrupt_disable_count = previous - 1;

        if (previous == 1) {
            current_task.setKnownExecutor();
            arch.interrupts.enable();
        }
    }

    pub fn incrementEnableAccessToUserMemory(current_task: Task.Current) void {
        if (core.is_debug) std.debug.assert(current_task.task.type == .user);

        const previous = current_task.task.enable_access_to_user_memory_count;
        current_task.task.enable_access_to_user_memory_count = previous + 1;

        if (previous == 0) {
            arch.paging.enableAccessToUserMemory();
        }
    }

    pub fn decrementEnableAccessToUserMemory(current_task: Task.Current) void {
        if (core.is_debug) std.debug.assert(current_task.task.type == .user);

        const previous = current_task.task.enable_access_to_user_memory_count;
        current_task.task.enable_access_to_user_memory_count = previous - 1;

        if (previous == 1) {
            arch.paging.disableAccessToUserMemory();
        }
    }

    /// Maybe preempt the current task.
    ///
    /// The scheduler lock must *not* be held.
    pub fn maybePreempt(current_task: Task.Current) void {
        // TODO: do more than just preempt everytime

        if (core.is_debug) {
            Scheduler.assertSchedulerNotLocked(current_task);
            std.debug.assert(current_task.task.spinlocks_held == 0);
            std.debug.assert(current_task.task.state == .running);
        }

        Scheduler.lockScheduler(current_task);
        defer Scheduler.unlockScheduler(current_task);

        if (Scheduler.isEmpty()) return;

        log.verbose(current_task, "preempting {f}", .{current_task});

        current_task.yield();
    }

    /// Yields the current task.
    ///
    /// Must be called with the scheduler lock held.
    pub fn yield(current_task: Task.Current) void {
        if (core.is_debug) {
            Scheduler.assertSchedulerLocked(current_task);
            std.debug.assert(current_task.task.spinlocks_held == 1); // only the scheduler lock is held
        }

        const new_task = Scheduler.getNextTask(current_task) orelse return; // no tasks to run

        if (core.is_debug) std.debug.assert(current_task.task.state == .running);

        if (current_task.task.is_scheduler_task) {
            log.verbose(current_task, "switching from idle to {f}", .{new_task});
            current_task.switchToTaskFromIdleYield(new_task);
            unreachable;
        }

        if (core.is_debug) std.debug.assert(current_task.task != new_task);

        log.verbose(current_task, "switching from {f} to {f}", .{ current_task, new_task });

        current_task.switchToTaskFromTaskYield(new_task);
    }

    /// Drops the current task out of the scheduler.
    ///
    /// Decrements the reference count of the task to remove the implicit self reference.
    ///
    /// The scheduler lock must be held when this function is called.
    pub fn drop(current_task: Task.Current) noreturn {
        if (core.is_debug) {
            Scheduler.assertSchedulerLocked(current_task);
            std.debug.assert(current_task.task.spinlocks_held == 1); // only the scheduler lock is held
        }

        dropWithDeferredAction(current_task, .{
            .action = struct {
                fn action(inner_current_task: Task.Current, old_task: *Task, _: usize) void {
                    old_task.state = .{ .dropped = .{} };
                    old_task.decrementReferenceCount(inner_current_task);
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
    pub fn dropWithDeferredAction(current_task: Task.Current, deferred_action: DeferredAction) void {
        if (core.is_debug) {
            std.debug.assert(!current_task.task.is_scheduler_task); // scheduler task cannot be dropped
            Scheduler.assertSchedulerLocked(current_task);
            std.debug.assert(current_task.task.state == .running);
        }

        const new_task = Scheduler.getNextTask(current_task) orelse {
            log.verbose(current_task, "switching from {f} to idle with a deferred action", .{current_task});
            switchToIdleDeferredAction(current_task, deferred_action);
            return;
        };
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

    pub fn onInterruptEntry() struct { Task.Current, StateBeforeInterrupt } {
        if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

        const executor = arch.getCurrentExecutor();
        const current_task = executor.current_task;
        if (core.is_debug) std.debug.assert(current_task.state.running == executor);

        const before_interrupt_interrupt_disable_count = current_task.interrupt_disable_count;
        current_task.interrupt_disable_count = before_interrupt_interrupt_disable_count + 1;

        const before_interrupt_enable_access_to_user_memory_count = current_task.enable_access_to_user_memory_count;
        current_task.enable_access_to_user_memory_count = 0;

        if (before_interrupt_enable_access_to_user_memory_count != 0) {
            @branchHint(.unlikely);
            arch.paging.disableAccessToUserMemory();
        }

        current_task.known_executor = current_task.state.running;

        return .{
            .{ .task = current_task }, .{
                .interrupt_disable_count = before_interrupt_interrupt_disable_count,
                .enable_access_to_user_memory_count = before_interrupt_enable_access_to_user_memory_count,
            },
        };
    }

    /// Tracks the state of the task before an interrupt was triggered.
    ///
    /// Stored seperately from the task to allow nested interrupts.
    pub const StateBeforeInterrupt = struct {
        interrupt_disable_count: u32,
        enable_access_to_user_memory_count: u32,

        pub fn onInterruptExit(state_before_interrupt: StateBeforeInterrupt, current_task: Task.Current) void {
            current_task.task.interrupt_disable_count = state_before_interrupt.interrupt_disable_count;

            const before_interrupt_enable_access_to_user_memory_count = state_before_interrupt.enable_access_to_user_memory_count;
            const current_enable_access_to_user_memory_count = current_task.task.enable_access_to_user_memory_count;

            current_task.task.enable_access_to_user_memory_count = before_interrupt_enable_access_to_user_memory_count;

            if (current_enable_access_to_user_memory_count != before_interrupt_enable_access_to_user_memory_count) {
                @branchHint(.unlikely);

                if (before_interrupt_enable_access_to_user_memory_count == 0) {
                    arch.paging.disableAccessToUserMemory();
                } else {
                    arch.paging.enableAccessToUserMemory();
                }
            }

            current_task.setKnownExecutor();
        }
    };

    /// Called when panicking to fetch the current task.
    ///
    /// Interrupts must already be disabled when this function is called.
    pub fn panicked() Task.Current {
        std.debug.assert(!arch.interrupts.areEnabled());

        const executor = arch.getCurrentExecutor();
        const current_task = executor.current_task;

        current_task.interrupt_disable_count += 1;
        current_task.known_executor = executor;

        return .{ .task = current_task };
    }

    pub inline fn format(current_task: Current, writer: *std.Io.Writer) !void {
        return current_task.task.format(writer);
    }

    /// Set the `known_executor` field of the task based on the state of the task.
    inline fn setKnownExecutor(current_task: Task.Current) void {
        if (current_task.task.interrupt_disable_count != 0) {
            current_task.task.known_executor = current_task.task.state.running;
        } else {
            current_task.task.known_executor = null;
        }
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
                    Scheduler.assertSchedulerLocked(inner_current_task);
                    std.debug.assert(inner_current_task.task.interrupt_disable_count == 1);
                    std.debug.assert(inner_current_task.task.spinlocks_held == 1);
                }

                idle(inner_current_task);
                @panic("idle returned");
            }
        };

        const executor = current_task.knownExecutor();
        const scheduler_task = &executor.scheduler_task;
        if (core.is_debug) std.debug.assert(scheduler_task.state == .ready);

        current_task.beforeSwitchTask(scheduler_task);

        scheduler_task.state = .{ .running = executor };
        scheduler_task.known_executor = executor;
        executor.current_task = scheduler_task;

        const old_task = current_task.task;

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

        current_task.beforeSwitchTask(new_task);

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

        current_task.beforeSwitchTask(new_task);

        new_task.state = .{ .running = executor };
        new_task.known_executor = executor;
        executor.current_task = new_task;

        old_task.state = .ready;
        Scheduler.queueTask(current_task, current_task.task);

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
                    Scheduler.assertSchedulerLocked(inner_current_task);
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

        current_task.beforeSwitchTask(new_task);

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

    fn beforeSwitchTask(
        current_task: Task.Current,
        new_task: *Task,
    ) void {
        const old_task = current_task.task;

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
};

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

        if (!Scheduler.isEmpty()) {
            current_task.yield();
        }

        Scheduler.unlockScheduler(current_task);

        arch.halt();

        Scheduler.lockScheduler(current_task);
    }
}

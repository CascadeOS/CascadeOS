// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const Process = kernel.Process;
const core = @import("core");

const log = kernel.debug.log.scoped(.task);

pub const Current = extern struct {
    task: *Task,

    /// Returns the executor that the current task is running on if it is known.
    ///
    /// Asserts that the `known_executor` field is non-null.
    pub fn knownExecutor(current_task: Current) *kernel.Executor {
        return current_task.task.known_executor.?;
    }

    pub fn current() Task.Current {
        return .{ .task = arch.getCurrentTask() };
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
            std.debug.assert(current_task.task.spinlocks_held == 0);
            std.debug.assert(current_task.task.state == .running);
        }

        const scheduler_handle: Task.SchedulerHandle = .get(current_task);
        defer scheduler_handle.unlock(current_task);

        if (scheduler_handle.isEmpty(current_task)) return;

        log.verbose(current_task, "preempting {f}", .{current_task});

        scheduler_handle.yield(current_task);
    }

    /// Fetches the current task, and enables interrupts.
    pub fn onSyscallEntry() Task.Current {
        if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

        const executor = arch.unsafeGetCurrentExecutor();
        const current_task = executor.current_task;
        if (core.is_debug) {
            std.debug.assert(current_task.state.running == executor);
            std.debug.assert(current_task.interrupt_disable_count == 0);
            std.debug.assert(current_task.enable_access_to_user_memory_count == 0);
        }

        arch.interrupts.enable();

        return .{ .task = current_task };
    }

    pub fn onInterruptEntry() struct { Task.Current, StateBeforeInterrupt } {
        if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

        const executor = arch.unsafeGetCurrentExecutor();
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

        const executor = arch.unsafeGetCurrentExecutor();
        const current_task = executor.current_task;
        if (core.is_debug) std.debug.assert(current_task.state.running == executor);

        current_task.interrupt_disable_count += 1;
        current_task.known_executor = current_task.state.running;

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
};

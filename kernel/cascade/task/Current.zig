// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const log = cascade.debug.log.scoped(.task);

const Current = @This();

task: *cascade.Task,

/// Returns the executor that the current task is running on if it is known.
///
/// Assumes that the `known_executor` field is non-null.
pub inline fn knownExecutor(current_task: Current) *cascade.Executor {
    return current_task.task.known_executor orelse unreachable;
}

pub inline fn get() Current {
    return .{ .task = arch.Task.getCurrent() };
}

pub fn incrementInterruptDisable(current_task: Current) void {
    arch.Executor.current.disableInterrupts();

    const previous = current_task.task.interrupt_disable_count.fetchAdd(1, .acq_rel);
    if (core.is_debug) std.debug.assert(previous < std.math.maxInt(u32));

    current_task.task.known_executor = current_task.task.state.running;
}

pub fn decrementInterruptDisable(current_task: Current) void {
    if (core.is_debug) std.debug.assert(!arch.Executor.current.interruptsEnabled());

    const previous = current_task.task.interrupt_disable_count.fetchSub(1, .acq_rel);
    if (core.is_debug) std.debug.assert(previous > 0);

    if (previous == 1) {
        current_task.setKnownExecutor();
        arch.Executor.current.enableInterrupts();
    }
}

pub fn incrementMigrationDisable(current_task: Current) void {
    const previous = current_task.task.migration_disable_count.fetchAdd(1, .acq_rel);
    if (core.is_debug) std.debug.assert(previous < std.math.maxInt(u32));

    current_task.task.known_executor = current_task.task.state.running;
}

pub fn decrementMigrationDisable(current_task: Current) void {
    const previous = current_task.task.migration_disable_count.fetchSub(1, .acq_rel);
    if (core.is_debug) std.debug.assert(previous > 0);

    if (previous == 1) current_task.setKnownExecutor();
}

/// Maybe preempt the current task.
///
/// The scheduler lock must *not* be held.
pub fn maybePreempt(current_task: Current) void {
    // TODO: do more than just preempt everytime

    if (core.is_debug) {
        std.debug.assert(current_task.task.spinlocks_held == 0);
        std.debug.assert(current_task.task.state == .running);
    }

    const scheduler_handle: cascade.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();

    if (scheduler_handle.isEmpty()) return;

    log.verbose("preempting {f}", .{current_task});

    scheduler_handle.yield();
}

pub fn onInterruptEntry() StateBeforeInterrupt {
    if (core.is_debug) std.debug.assert(!arch.Executor.current.interruptsEnabled());

    const task = arch.Task.getCurrent();

    const before_interrupt_interrupt_disable_count = task.interrupt_disable_count.fetchAdd(1, .monotonic);
    const before_interrupt_access_user_memory = switch (task.type) {
        .kernel => false,
        .user => blk: {
            const thread: *cascade.user.Thread = .from(task);
            const before_interrupt_access_user_memory = thread.access_user_memory.swap(false, .monotonic);

            if (before_interrupt_access_user_memory) {
                @branchHint(.unlikely);
                arch.Executor.current.disableAccessToUserMemory();
            }

            break :blk before_interrupt_access_user_memory;
        },
    };

    task.known_executor = task.state.running;

    return .{
        .interrupt_disable_count = before_interrupt_interrupt_disable_count,
        .access_user_memory = before_interrupt_access_user_memory,
    };
}

/// Tracks the state of the task before an interrupt was triggered.
///
/// Stored seperately from the task to allow nested interrupts.
pub const StateBeforeInterrupt = struct {
    interrupt_disable_count: u32,
    access_user_memory: bool,

    pub fn onInterruptExit(state_before_interrupt: StateBeforeInterrupt) void {
        const current_task: Current = .get();

        current_task.task.interrupt_disable_count.store(state_before_interrupt.interrupt_disable_count, .monotonic);

        switch (current_task.task.type) {
            .kernel => {},
            .user => {
                const thread: *cascade.user.Thread = .from(current_task.task);

                const before_interrupt_access_user_memory = state_before_interrupt.access_user_memory;
                const current_access_user_memory = thread.access_user_memory.swap(
                    before_interrupt_access_user_memory,
                    .monotonic,
                );

                if (current_access_user_memory != before_interrupt_access_user_memory) {
                    @branchHint(.unlikely);

                    if (before_interrupt_access_user_memory) {
                        arch.Executor.current.disableAccessToUserMemory();
                    } else {
                        arch.Executor.current.enableAccessToUserMemory();
                    }
                }
            },
        }

        current_task.setKnownExecutor();
    }
};

/// Called when panicking to fetch the current task.
///
/// Interrupts must already be disabled when this function is called.
pub fn panicked() Current {
    std.debug.assert(!arch.Executor.current.interruptsEnabled());

    const task = arch.Task.getCurrent();

    _ = task.interrupt_disable_count.fetchAdd(1, .acq_rel);
    task.known_executor = task.state.running;

    return .{ .task = task };
}

pub inline fn format(current_task: Current, writer: *std.Io.Writer) !void {
    return current_task.task.format(writer);
}

/// Set the `known_executor` field of the task based on the state of the task.
fn setKnownExecutor(current_task: Current) void {
    if (current_task.task.interrupt_disable_count.load(.acquire) != 0 or
        current_task.task.migration_disable_count.load(.acquire) != 0)
    {
        current_task.task.known_executor = current_task.task.state.running;
        return;
    }

    current_task.task.known_executor = null;
}

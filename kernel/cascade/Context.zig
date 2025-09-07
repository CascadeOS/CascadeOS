// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A context for a running task.
//!
//! Stored within the `Task` struct to allow fetching the task with `@fieldParentPtr`.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const Context = @This();

/// Set to the executor the current task is running on if the state of the context means that the executor cannot
/// change underneath us (for example when interrupts are disabled).
///
/// Set to null otherwise.
///
/// The value is undefined when the task is not running.
executor: ?*cascade.Executor,

/// Tracks the depth of nested interrupt disables.
interrupt_disable_count: u32 = 1, // tasks always start with interrupts disabled

spinlocks_held: u32,
scheduler_locked: bool,

pub inline fn task(context: *Context) *Task {
    return @fieldParentPtr("context", context);
}

pub fn current() *Context {
    // TODO: some architectures can do this without disabling interrupts

    arch.interrupts.disable();

    const executor = arch.getCurrentExecutor();
    const current_task = executor.current_task;
    if (core.is_debug) std.debug.assert(current_task.state.running == executor);

    const context: *Context = &current_task.context;
    if (context.interrupt_disable_count == 0) arch.interrupts.enable();

    return context;
}

pub const InterruptExit = struct {
    previous_interrupt_disable_count: u32,

    pub fn exit(interrupt_exit: InterruptExit, context: *Context) void {
        context.interrupt_disable_count = interrupt_exit.previous_interrupt_disable_count;
        context.setExecutor();
    }
};

pub fn onInterruptEntry() struct { *Context, InterruptExit } {
    if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

    const executor = arch.getCurrentExecutor();
    const current_task = executor.current_task;
    if (core.is_debug) std.debug.assert(current_task.state.running == executor);

    const context: *Context = &current_task.context;
    const previous_interrupt_disable_count = context.interrupt_disable_count;

    context.interrupt_disable_count = previous_interrupt_disable_count + 1;
    context.executor = current_task.state.running;

    return .{ context, .{ .previous_interrupt_disable_count = previous_interrupt_disable_count } };
}

pub fn incrementInterruptDisable(context: *Context) void {
    const previous = context.interrupt_disable_count;

    if (previous == 0) {
        if (core.is_debug) std.debug.assert(arch.interrupts.areEnabled());
        arch.interrupts.disable();
        context.executor = context.task().state.running;
    } else if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

    context.interrupt_disable_count = previous + 1;
}

pub fn decrementInterruptDisable(context: *Context) void {
    if (core.is_debug) std.debug.assert(!arch.interrupts.areEnabled());

    const previous = context.interrupt_disable_count;
    context.interrupt_disable_count = previous - 1;

    if (previous == 1) {
        context.setExecutor();
        arch.interrupts.enable();
    }
}

/// Drops the current task out of the scheduler.
///
/// Decrements the reference count of the task to remove the implicit self reference.
///
/// The scheduler lock must be held when this function is called.
pub fn drop(context: *cascade.Context) noreturn {
    if (core.is_debug) {
        cascade.scheduler.assertSchedulerLocked(context);
        std.debug.assert(context.spinlocks_held == 1); // only the scheduler lock is held
    }

    cascade.scheduler.drop(context, .{
        .action = struct {
            fn action(new_context: *cascade.Context, old_task: *cascade.Task, _: usize) void {
                old_task.state = .{ .dropped = .{} };
                old_task.decrementReferenceCount(new_context);
            }
        }.action,
        .arg = undefined,
    });
    @panic("dropped task returned");
}

/// Set the `executor` field of the context based on the state of the context.
inline fn setExecutor(context: *cascade.Context) void {
    if (context.interrupt_disable_count != 0) {
        context.executor = context.task().state.running;
    } else {
        context.executor = null;
    }
}

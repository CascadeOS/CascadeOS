// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const Task = @This();

_name: Name,

state: State,

/// The stack used by this task in kernel mode.
stack: kernel.Stack,

/// Used for various linked lists.
next_task_node: containers.SingleNode = .empty,

/// Tracks the depth of nested preemption disables.
preemption_disable_count: u32 = 0,

/// Whenever we skip preemption, we set this to true.
///
/// Then when we re-enable preemption, we check this flag.
preemption_skipped: bool = false,

/// The executor that this task is running on.
///
/// This is only set when the task is running and when either `preemption_disable_count == 0` or
/// `executor.interrupt_disable_count == 0`.
executor: ?*kernel.Executor = null,

is_idle_task: bool,

pub fn name(self: *const Task) []const u8 {
    return self._name.constSlice();
}

pub const State = enum {
    ready,
    running,
    blocked,
    dropped,
};

pub fn getCurrent() *Task {
    arch.interrupts.disableInterrupts();

    const executor = arch.rawGetCurrentExecutor();
    const current_task = executor.current_task;

    if (executor.interrupt_disable_count == 0) {
        arch.interrupts.enableInterrupts();
    } else {
        current_task.executor = executor;
    }

    return current_task;
}

pub fn incrementInterruptDisable(self: *Task) void {
    if (self.executor) |executor| {
        std.debug.assert(!arch.interrupts.areEnabled());
        std.debug.assert(executor.current_task == self);

        executor.interrupt_disable_count += 1;

        return;
    }

    arch.interrupts.disableInterrupts();

    const executor = arch.rawGetCurrentExecutor();
    std.debug.assert(executor.current_task == self);

    executor.interrupt_disable_count += 1;
    self.executor = executor;
}

pub fn decrementInterruptDisable(self: *Task) void {
    std.debug.assert(self.executor != null);
    std.debug.assert(!arch.interrupts.areEnabled());

    const executor = self.executor.?;
    std.debug.assert(executor == arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == self);

    executor.interrupt_disable_count -= 1;

    if (executor.interrupt_disable_count == 0) {
        if (self.preemption_disable_count == 0) self.executor = null;

        arch.interrupts.enableInterrupts();
    }
}

pub fn incrementPreemptionDisable(self: *Task) void {
    self.preemption_disable_count += 1;

    const executor = self.executor orelse blk: {
        const executor = arch.rawGetCurrentExecutor();
        self.executor = executor;
        break :blk executor;
    };
    std.debug.assert(executor.current_task == self);
    std.debug.assert(self.executor == executor);
}

pub fn decrementPreemptionDisable(self: *Task) void {
    const executor = self.executor.?;
    std.debug.assert(executor == arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == self);

    self.preemption_disable_count -= 1;

    if (self.preemption_disable_count == 0) {
        if (executor.interrupt_disable_count == 0) self.executor = null;
        if (self.preemption_skipped) kernel.scheduler.maybePreempt(self);
    }
}

pub const Name = std.BoundedArray(u8, kernel.config.task_name_length);

pub fn print(task: *const Task, writer: std.io.AnyWriter, _: usize) !void {
    // Task(task.name)

    try writer.writeAll("Task(");
    try writer.writeAll(task.name());
    try writer.writeByte(')');
}

pub inline fn format(
    task: *const Task,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return if (@TypeOf(writer) == std.io.AnyWriter)
        print(task, writer, 0)
    else
        print(task, writer.any(), 0);
}

fn __helpZls() void {
    Task.print(undefined, @as(std.fs.File.Writer, undefined), 0);
}

pub inline fn fromNode(node: *containers.SingleNode) *Task {
    return @fieldParentPtr("next_task_node", node);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");
const arch = @import("arch");

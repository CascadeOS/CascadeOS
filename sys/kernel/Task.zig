// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const Task = @This();

_name: Name,

state: State,

/// The stack used by this task in kernel mode.
stack: kernel.Stack,

/// Used for various linked lists.
next_task_node: containers.SingleNode = .{},

/// Tracks the depth of nested preemption disables.
preemption_disable_count: u32 = 0,

/// Whenever we skip preemption, we set this to true.
///
/// Then when we re-enable preemption, we check this flag.
preemption_skipped: bool = false,

pub fn name(self: *const Task) []const u8 {
    return self._name.constSlice();
}

pub const State = enum {
    ready,
    running,
    blocked,
    dropped,
};

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

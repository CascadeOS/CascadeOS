// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const containers = @import("containers");

const Task = @This();

id: Id,
_name: Name,

state: State = .ready,

/// The stack used by this task in kernel mode.
stack: kernel.Stack,

/// The process that this task belongs to.
///
/// `null` if this is a kernel task.
process: ?*kernel.Process,

/// Used to track the next task in any linked list.
///
/// Used in the ready queue, wait lists, etc.
next_task_node: containers.SingleNode = .{},

pub fn name(self: *const Task) []const u8 {
    return self._name.constSlice();
}

pub inline fn isKernel(self: *const Task) bool {
    return self.process == null;
}

pub inline fn fromNode(node: *containers.SingleNode) *Task {
    return @fieldParentPtr("next_task_node", node);
}

pub const State = enum {
    ready,
    running,
    blocked,
    dropped,
};

pub const Name = std.BoundedArray(u8, kernel.config.task_name_length);
pub const Id = enum(u32) {
    _,
};

pub fn print(task: *const Task, writer: std.io.AnyWriter, indent: usize) !void {
    // Process(process.name)::Task(task.name) or Kernel::Task(task.name)

    if (task.process) |process| {
        try process.print(writer, indent);
    } else {
        try writer.writeAll("Kernel");
    }

    try writer.writeAll("::Task(");
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

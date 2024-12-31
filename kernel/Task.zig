// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const Task = @This();

_name: Name,

state: State,

/// The stack used by this task in kernel mode.
stack: kernel.Stack,

pub fn name(self: *const Task) []const u8 {
    return self._name.constSlice();
}

pub const State = union(enum) {
    ready,
    /// It is the accessors responsibility to ensure that the executor does not change.
    running: *kernel.Executor,
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

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.

const Executor = @This();

id: Id,

panicked: std.atomic.Value(bool) = .init(false),

/// The currently running task.
current_task: *kernel.Task,

/// This executor's idle task.
///
/// The `stack_pointer` of this task's stack should never be modified in place, any push/pop operations should be done
/// on a *copy* of the stack.
idle_task: kernel.Task,

arch: @import("arch").PerExecutor,

pub fn isCurrentTaskIdle(executor: *const Executor) bool {
    return executor.current_task == &executor.idle_task;
}

/// A unique identifier for the executor.
pub const Id = enum(u32) {
    bootstrap = 0,

    none = std.math.maxInt(u32),

    _,

    pub fn print(id: Id, writer: std.io.AnyWriter, indent: usize) !void {
        // Executor(id)

        _ = indent;

        try writer.writeAll("Executor(");
        try std.fmt.formatInt(@intFromEnum(id), 10, .lower, .{}, writer);
        try writer.writeByte(')');
    }

    pub inline fn format(
        id: Id,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            Id.print(id, writer, 0)
        else
            Id.print(id, writer.any(), 0);
    }
};

pub fn print(executor: *const Executor, writer: std.io.AnyWriter, indent: usize) !void {
    try executor.id.print(writer, indent);
}

pub inline fn format(
    executor: *const Executor,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return if (@TypeOf(writer) == std.io.AnyWriter)
        print(executor, writer, 0)
    else
        print(executor, writer.any(), 0);
}

fn __helpZls() void {
    Executor.print(undefined, @as(std.fs.File.Writer, undefined), 0);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

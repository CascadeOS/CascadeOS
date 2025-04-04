// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Executor = @This();

id: Id,

current_task: *kernel.Task,

panicked: std.atomic.Value(bool) = .init(false),

idle_task: kernel.Task,

arch: kernel.arch.PerExecutor,

/// List of `kernel.vmm.FlushRequest` objects that need to be actioned.
flush_requests: containers.AtomicSinglyLinkedLIFO = .{},

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

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const Thread = @This();

id: Thread.Id,

state: State = .ready,

priority: kernel.scheduler.Priority,

process: *kernel.scheduler.Process,

kernel_stack: kernel.Stack,

next_thread: ?*Thread = null,

pub const State = enum {
    ready,
    running,
};

pub const Id = enum(usize) {
    none = 0,

    _,
};

pub fn print(self: *const Thread, writer: anytype) !void {
    try writer.writeAll(self.process.name());
    try writer.writeByte(':');
    try std.fmt.formatInt(@intFromEnum(self.id), 10, .lower, .{}, writer);
}

pub inline fn format(
    self: *const Thread,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    return Thread.print(self, writer);
}

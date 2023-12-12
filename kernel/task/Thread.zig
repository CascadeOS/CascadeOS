// SPDX-License-Identifier: MIT

const arch = kernel.arch;
const core = @import("core");
const kernel = @import("kernel");
const task = kernel.task;
const std = @import("std");

const Thread = @This();

id: Thread.Id,

state: State = .ready,

process: *task.Process,

kernel_stack: task.Stack,

next_thread: ?*Thread = null,

pub const State = enum {
    ready,
    running,
};

pub const Id = enum(usize) {
    _,
};

pub fn print(self: *const Thread, writer: anytype) !void {
    try writer.writeAll("Thread<");
    try std.fmt.formatInt(@intFromEnum(self.process.id), 10, .lower, .{}, writer);
    try writer.writeByte('-');
    try std.fmt.formatInt(@intFromEnum(self.id), 10, .lower, .{}, writer);
    try writer.writeByte('>');
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

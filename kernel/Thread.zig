// SPDX-License-Identifier: MIT

const arch = kernel.arch;
const core = @import("core");
const kernel = @import("kernel");
const Stack = kernel.Stack;
const std = @import("std");

const Thread = @This();

id: Thread.Id,

process: *kernel.Process,

kernel_stack: Stack,

next_thread: ?*Thread = null,

pub const Id = enum(usize) {
    _,
};

pub fn print(self: *const Thread, writer: anytype) !void {
    try writer.writeAll("Thread<");
    try std.fmt.formatInt(@intFromEnum(self.id), 10, .lower, .{}, writer);
    try writer.writeAll(" @ ");
    try self.process.print(writer);
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

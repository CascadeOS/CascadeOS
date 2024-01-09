// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const Process = @This();

id: Id,
_name: Name,

page_table: *kernel.arch.paging.PageTable,

pub fn name(self: *const Process) []const u8 {
    return self._name.constSlice();
}

pub fn isKernel(self: *const Process) bool {
    return self == &kernel.kernel_process;
}

pub const PROCESS_NAME_LEN: usize = 16;
pub const Name = std.BoundedArray(u8, PROCESS_NAME_LEN);

pub const Id = enum(usize) {
    none = 0,

    kernel = 1,

    _,
};

pub fn print(self: *const Process, writer: anytype) !void {
    try writer.writeAll("Process<");
    try std.fmt.formatInt(@intFromEnum(self.id), 10, .lower, .{}, writer);
    try writer.writeAll(" - '");
    try writer.writeAll(self.name());
    try writer.writeAll("'>");
}

pub inline fn format(
    self: *const Process,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    return print(self, writer);
}

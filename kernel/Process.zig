// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const Process = @This();

id: Id,
_name: Name,

page_table: *kernel.arch.paging.PageTable,

pub fn name(self: *const Process) []const u8 {
    return self._name.constSlice();
}

pub fn loadPageTable(self: *const Process) void {
    kernel.vmm.switchToPageTable(self.page_table);
}

pub const Name = std.BoundedArray(u8, kernel.config.process_name_length);
pub const Id = enum(u64) {
    _,
};

pub fn print(process: *const Process, writer: std.io.AnyWriter, indent: usize) !void {
    // Process(process.name)

    _ = indent;

    try writer.writeAll("Process(");
    try writer.writeAll(process.name());
    try writer.writeByte(')');
}

pub inline fn format(
    process: *const Process,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return if (@TypeOf(writer) == std.io.AnyWriter)
        print(process, writer, 0)
    else
        print(process, writer.any(), 0);
}

fn __helpZls() void {
    Process.print(undefined, @as(std.fs.File.Writer, undefined), 0);
}

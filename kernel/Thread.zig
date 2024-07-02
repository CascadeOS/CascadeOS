// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const containers = @import("containers");

const Thread = @This();

id: Id,
_name: Name,

state: State = .ready,

/// The process that this thread belongs to.
///
/// `null` if this is a kernel thread.
process: ?*kernel.Process,

kernel_stack: kernel.Stack,

/// Used to track the next thread in any linked list.
///
/// Used in the ready queue, wait lists, etc.
next_thread_node: containers.SingleNode = .{},

pub fn name(self: *const Thread) []const u8 {
    return self._name.constSlice();
}

pub inline fn isKernel(self: *const Thread) bool {
    return self.process == null;
}

pub inline fn fromNode(node: *containers.SingleNode) *Thread {
    return @fieldParentPtr("next_thread_node", node);
}

pub const State = enum {
    ready,
    running,
    blocked,
};

pub const Name = std.BoundedArray(u8, kernel.config.thread_name_length);
pub const Id = enum(u32) {
    _,
};

pub fn print(thread: *const Thread, writer: std.io.AnyWriter, indent: usize) !void {
    // Process(process.name)::Thread(thread.name) or Kernel::Thread(thread.name)

    if (thread.process) |process| {
        try process.print(writer, indent);
    } else {
        try writer.writeAll("Kernel");
    }

    try writer.writeAll("::Thread(");
    try writer.writeAll(thread.name());
    try writer.writeByte(')');
}

pub inline fn format(
    thread: *const Thread,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return if (@TypeOf(writer) == std.io.AnyWriter)
        print(thread, writer, 0)
    else
        print(thread, writer.any(), 0);
}

fn __helpZls() void {
    Thread.print(undefined, @as(std.fs.File.Writer, undefined), 0);
}

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const Cpu = @This();

id: Id,

/// Tracks the number of times we have disabled interrupts.
///
/// This allows support for nested disables.
interrupt_disable_count: u32,

/// The stack used for idle.
///
/// Also used during the move from the bootloader provided stack until we start scheduling.
idle_stack: kernel.Stack,

/// The currently running thread.
///
/// This is set to `null` when the processor is idle and also before we start scheduling.
current_thread: ?*kernel.Thread = null,

arch: kernel.arch.ArchCpu,

pub const Id = enum(u32) {
    bootstrap = 0,
    none = std.math.maxInt(u32),

    _,
};

pub fn print(cpu: *const Cpu, writer: std.io.AnyWriter, indent: usize) !void {
    // Cpu(id)

    _ = indent;

    try writer.writeAll("Cpu(");
    try std.fmt.formatInt(@intFromEnum(cpu.id), 10, .lower, .{}, writer);
    try writer.writeByte(')');
}

pub inline fn format(
    cpu: *const Cpu,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return if (@TypeOf(writer) == std.io.AnyWriter)
        print(cpu, writer, 0)
    else
        print(cpu, writer.any(), 0);
}

fn __helpZls() void {
    Cpu.print(undefined, @as(std.fs.File.Writer, undefined), 0);
}

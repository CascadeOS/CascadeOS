// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const Cpu = @This();

id: Id,

/// Tracks the depth of nested interrupt disables.
///
/// Preemption is disabled when interrupts are disabled.
interrupt_disable_count: u32 = 1, // interrupts start disabled

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

    pub fn print(id: Id, writer: std.io.AnyWriter, indent: usize) !void {
        // Cpu(id)

        _ = indent;

        try writer.writeAll("Cpu(");
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

pub fn print(cpu: *const Cpu, writer: std.io.AnyWriter, indent: usize) !void {
    try cpu.id.print(writer, indent);
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

/// The list of cpus in the system.
///
/// Initialized during `init.initStage1`.
var cpus: []Cpu = undefined;

/// Fetch a specific cpus `Cpu` struct.
///
/// `id` must not be `.none`
pub fn getCpu(id: Id) *Cpu {
    core.debugAssert(id != .none);

    return &cpus[@intFromEnum(id)];
}

pub const init = struct {
    pub inline fn setCpus(cpu_slice: []Cpu) void {
        cpus = cpu_slice;
    }
};

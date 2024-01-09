// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.
//!
//! Even though this is called `Processor` it represents a single core in a multi-core system.

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const Processor = @This();

id: Id,

panicked: bool = false,

/// The stack used for idle.
///
/// Also used during the move from the bootloader provided stack until we start scheduling.
idle_stack: kernel.Stack,

/// The currently running thread.
///
/// This is set to `null` when the processor is idle and also before we start scheduling.
current_thread: ?*kernel.scheduler.Thread = null,

arch: kernel.arch.ArchProcessor,

pub const Id = enum(usize) {
    none = 0,

    bootstrap = 1,

    _,

    pub fn print(self: Id, writer: anytype) !void {
        std.fmt.formatInt(
            @intFromEnum(self),
            10,
            .lower,
            .{ .width = 2, .fill = '0' },
            writer,
        ) catch unreachable;
    }

    pub inline fn format(
        self: Id,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        return print(self, writer);
    }
};

/// The list of processors in the system.
///
/// Initialized during `init.initKernelStage1`.
pub var _all: []Processor = undefined;

pub fn get(id: Id) *Processor {
    return &_all[@intFromEnum(id) - 1];
}

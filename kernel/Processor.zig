// SPDX-License-Identifier: MIT

//! Represents a single execution resource.
//!
//! Even though this is called `Processor` it represents a single core in a multi-core system.

const arch = kernel.arch;
const core = @import("core");
const kernel = @import("kernel");
const task = kernel.task;
const std = @import("std");

/// The list of processors in the system.
///
/// Initialized during `init.initKernelStage1`.
pub var all: []Processor = undefined;

const Processor = @This();

id: Id,

panicked: bool = false,

/// The stack used for idle.
///
/// Also used during the move from the bootloader provided stack until we start scheduling.
idle_stack: task.Stack,

/// The currently running thread.
///
/// This is set to `null` when the processor is idle and also before we start scheduling.
current_thread: ?*task.Thread = null,

arch: arch.ArchProcessor,

pub const Id = enum(usize) {
    bootstrap = 0,

    _,

    pub fn print(self: Id, writer: anytype) !void {
        std.fmt.formatInt(
            @intFromEnum(self),
            10,
            .lower,
            .{ .width = 2, .fill = '0' }, // TODO: What should the width be?
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

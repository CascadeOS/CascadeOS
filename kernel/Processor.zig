// SPDX-License-Identifier: MIT

//! Represents a single execution resource.
//!
//! Even though this is called `Processor` it represents a single core in a multi-core system.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

/// The list of processors in the system.
///
/// Initialized during `init.initKernelStage1`.
pub var all: []Processor = undefined;

const Processor = @This();

id: Id,

state: State,

/// The stack used for idle.
///
/// Also used during the move from the bootloader provided stack until we start scheduling.
idle_stack: kernel.Stack,

_arch: kernel.arch.ArchProcessor,

pub inline fn get() *Processor {
    return kernel.arch.getProcessor();
}

pub inline fn arch(self: *Processor) *kernel.arch.ArchProcessor {
    return &self._arch;
}

pub const State = enum {
    /// The processor is idle.
    idle,

    /// The processor is running in user-space.
    user,

    /// The processor is running in kernel-space.
    kernel,

    /// The processor has panicked.
    panic,
};

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

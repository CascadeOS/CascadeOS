// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Executor = @This();

id: Id,

current_task: *kernel.Task,

idle_task: kernel.Task,

arch: kernel.arch.PerExecutor,

/// List of `kernel.mem.FlushRequest` objects that need to be actioned.
flush_requests: containers.AtomicSinglyLinkedLIFO = .{},

pub const Id = enum(u32) {
    bootstrap = 0,

    none = std.math.maxInt(u32),

    _,

    pub inline fn format(
        id: Id,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("Executor({d})", .{@intFromEnum(id)});
    }
};

pub inline fn format(
    executor: *const Executor,
    writer: *std.Io.Writer,
) !void {
    return executor.id.format(writer);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

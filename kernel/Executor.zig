// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Executor = @This();

id: Id,

current_task: *kernel.Task,

/// Used as the current task during idle and also during the transition between tasks when executing a deferred action.
utility_task: kernel.Task,

arch: kernel.arch.PerExecutor,

/// List of `kernel.mem.FlushRequest` objects that need to be actioned.
flush_requests: core.containers.AtomicSinglyLinkedList = .{},

// used during `kernel.debug.interruptSourcePanic`
interrupt_source_panic_buffer: [kernel.config.interrupt_source_panic_buffer_size.value + interrupt_source_panic_truncated.len]u8 = undefined,
const interrupt_source_panic_truncated = "(msg truncated)";

/// Renders the given message using this executor's interrupt source panic buffer.
///
/// If the message is too large to fit in the buffer, the message is truncated.
pub fn renderInterruptSourcePanicMessage(
    current_executor: *Executor,
    comptime fmt: []const u8,
    args: anytype,
) []const u8 {
    // TODO: this treatment should be given to all panics
    std.debug.assert(current_executor == kernel.Task.getCurrent().state.running);

    const full_buffer = current_executor.interrupt_source_panic_buffer[0..];

    var bw: std.Io.Writer = .fixed(full_buffer[0..kernel.config.interrupt_source_panic_buffer_size.value]);

    bw.print(fmt, args) catch {
        @memcpy(
            full_buffer[kernel.config.interrupt_source_panic_buffer_size.value..],
            interrupt_source_panic_truncated,
        );
        return full_buffer;
    };

    return bw.buffered();
}

pub fn isUtilityTask(executor: *const Executor, task: *const kernel.Task) bool {
    return task == &executor.utility_task;
}

pub inline fn format(
    executor: *const Executor,
    writer: *std.Io.Writer,
) !void {
    return executor.id.format(writer);
}

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

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const Executor = @This();

/// Unique identifier per executor.
///
/// As no executor hotswapping is supported this is guaranteed to be the index of this executor in `globals.executors`.
id: Id,

current_task: *Task,

/// Used as the current task during idle and also during the transition between tasks when executing a deferred action.
scheduler_task: Task,

arch_specific: arch.PerExecutor,

/// List of `cascade.mem.FlushRequest` objects that need to be actioned.
flush_requests: core.containers.AtomicSinglyLinkedList = .{},

// used during `cascade.debug.interruptSourcePanic`
interrupt_source_panic_buffer: [cascade.config.executor.interrupt_source_panic_buffer_size.value + interrupt_source_panic_truncated.len]u8 = undefined,
const interrupt_source_panic_truncated = " (msg truncated)";

/// Renders the given message using this executor's interrupt source panic buffer.
///
/// If the message is too large to fit in the buffer, the message is truncated.
pub fn renderInterruptSourcePanicMessage(
    current_executor: *Executor,
    current_task: Task.Current,
    comptime fmt: []const u8,
    args: anytype,
) []const u8 {
    // TODO: this treatment should be given to all panics
    std.debug.assert(current_executor == current_task.knownExecutor());

    const full_buffer = current_executor.interrupt_source_panic_buffer[0..];

    var bw: std.Io.Writer = .fixed(full_buffer[0..cascade.config.executor.interrupt_source_panic_buffer_size.value]);

    bw.print(fmt, args) catch {
        @memcpy(
            full_buffer[cascade.config.executor.interrupt_source_panic_buffer_size.value..],
            interrupt_source_panic_truncated,
        );
        return full_buffer;
    };

    return bw.buffered();
}

pub fn executors() []Executor {
    return globals.executors;
}

pub inline fn format(
    executor: *const Executor,
    writer: *std.Io.Writer,
) !void {
    return executor.id.format(writer);
}

pub const Id = enum(u32) {
    _,

    pub inline fn format(
        id: Id,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("Executor({d})", .{@intFromEnum(id)});
    }
};

const globals = struct {
    var executors: []Executor = &.{};
};

pub const init = struct {
    pub fn setExecutors(executor_slice: []Executor) void {
        globals.executors = executor_slice;
    }
};

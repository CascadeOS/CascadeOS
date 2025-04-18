// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Task = @This();

id: Id,

_name: Name,

state: State,

/// The stack used by this task in kernel mode.
stack: kernel.Stack,

/// Tracks the depth of nested interrupt disables.
interrupt_disable_count: std.atomic.Value(u32) = .init(1), // fresh tasks start with interrupts disabled

/// Tracks the depth of nested preemption disables.
preemption_disable_count: std.atomic.Value(u32) = .init(0),

/// Whenever we skip preemption, we set this to true.
///
/// When we re-enable preemption, we check this flag.
preemption_skipped: std.atomic.Value(bool) = .init(false),

spinlocks_held: u32 = 1, // fresh tasks start with the scheduler locked

/// Used for various linked lists.
next_task_node: containers.SingleNode = .empty,

is_idle_task: bool = false,

pub fn name(self: *const Task) []const u8 {
    return self._name.constSlice();
}

pub const State = union(enum) {
    ready,
    /// It is the accessors responsibility to ensure that the executor does not change.
    running: *kernel.Executor,
    blocked,
    dropped,
};

pub fn getCurrent() *Task {
    kernel.arch.interrupts.disableInterrupts();

    const executor = kernel.arch.rawGetCurrentExecutor();
    const current_task = executor.current_task;
    std.debug.assert(current_task.state.running == executor);

    if (current_task.interrupt_disable_count.load(.monotonic) == 0) {
        kernel.arch.interrupts.enableInterrupts();
    }

    return current_task;
}

pub fn incrementInterruptDisable(self: *Task) void {
    kernel.arch.interrupts.disableInterrupts();

    _ = self.interrupt_disable_count.fetchAdd(1, .monotonic);

    const executor = self.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == self);
}

pub fn decrementInterruptDisable(self: *Task) void {
    std.debug.assert(!kernel.arch.interrupts.areEnabled());

    const executor = self.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == self);

    const previous = self.interrupt_disable_count.fetchSub(1, .monotonic);
    std.debug.assert(previous > 0);

    if (previous == 1) {
        kernel.arch.interrupts.enableInterrupts();
    }
}

pub fn incrementPreemptionDisable(self: *Task) void {
    _ = self.preemption_disable_count.fetchAdd(1, .monotonic);

    const executor = self.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == self);
}

pub fn decrementPreemptionDisable(self: *Task) void {
    const executor = self.state.running;
    std.debug.assert(executor == kernel.arch.rawGetCurrentExecutor());
    std.debug.assert(executor.current_task == self);

    const previous = self.preemption_disable_count.fetchSub(1, .monotonic);
    std.debug.assert(previous > 0);

    if (previous == 1 and self.preemption_skipped.load(.monotonic)) {
        kernel.scheduler.maybePreempt(self);
    }
}

pub const InterruptRestorer = struct {
    previous_value: u32,

    pub fn exit(self: InterruptRestorer, current_task: *Task) void {
        current_task.interrupt_disable_count.store(self.previous_value, .monotonic);
    }
};

pub fn onInterruptEntry() struct { *Task, InterruptRestorer } {
    std.debug.assert(!kernel.arch.interrupts.areEnabled());

    const executor = kernel.arch.rawGetCurrentExecutor();

    const current_task = executor.current_task;
    std.debug.assert(current_task.state.running == executor);

    const previous_value = current_task.interrupt_disable_count.fetchAdd(1, .monotonic);

    return .{ current_task, .{ .previous_value = previous_value } };
}

pub const Id = enum(u64) {
    none = std.math.maxInt(u64),

    _,
};

pub const Name = std.BoundedArray(u8, kernel.config.task_name_length);

pub fn print(task: *const Task, writer: std.io.AnyWriter, _: usize) !void {
    try writer.print("Task({s})", .{task.name()});
}

pub inline fn format(
    task: *const Task,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return if (@TypeOf(writer) == std.io.AnyWriter)
        print(task, writer, 0)
    else
        print(task, writer.any(), 0);
}

pub inline fn fromNode(node: *containers.SingleNode) *Task {
    return @fieldParentPtr("next_task_node", node);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

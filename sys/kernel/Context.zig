// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const Context = @This();

task: *kernel.Task,

/// Tracks the depth of nested preemption disables.
///
/// Must match the the `kernel.Task.preemption_disable_count` field.
preemption_disable_count: u32,

executor: ?*kernel.Executor,

/// Tracks the depth of nested intertupt disables.
///
/// Must match the the `kernel.Executor.interrupt_disable_count` field.
interrupt_disable_count: u32,

pub fn incrementInterruptDisable(self: *Context) void {
    const current_disable_count = self.interrupt_disable_count;

    const executor = if (current_disable_count == 0) executor: {
        std.debug.assert(arch.interrupts.areEnabled());

        arch.interrupts.disableInterrupts();

        const executor = arch.rawGetCurrentExecutor();

        self.executor = executor;

        break :executor executor;
    } else executor: {
        std.debug.assert(!arch.interrupts.areEnabled());

        break :executor self.executor.?;
    };

    std.debug.assert(executor.current_context == self);
    std.debug.assert(executor.interrupt_disable_count == current_disable_count);

    self.interrupt_disable_count = current_disable_count + 1;
    executor.interrupt_disable_count = current_disable_count + 1;
}

pub fn decrementInterruptDisable(self: *Context) void {
    const current_disable_count = self.interrupt_disable_count;
    std.debug.assert(current_disable_count != 0);
    std.debug.assert(!arch.interrupts.areEnabled());

    const executor = self.executor.?;

    std.debug.assert(executor.current_context == self);
    std.debug.assert(executor.interrupt_disable_count == current_disable_count);

    self.interrupt_disable_count = current_disable_count - 1;
    executor.interrupt_disable_count = current_disable_count - 1;

    if (current_disable_count == 1) {
        if (self.preemption_disable_count == 0) self.executor = null;

        arch.interrupts.enableInterrupts();
    }
}

pub fn incrementPreemptionDisable(self: *Context) void {
    const current_disable_count = self.preemption_disable_count;
    std.debug.assert(self.task.preemption_disable_count == current_disable_count);

    self.preemption_disable_count = current_disable_count + 1;
    self.task.preemption_disable_count = current_disable_count + 1;

    const executor = if (current_disable_count == 0) executor: {
        const executor = arch.rawGetCurrentExecutor();

        self.executor = executor;

        break :executor executor;
    } else self.executor.?;
    std.debug.assert(executor.current_context == self);
    std.debug.assert(executor.current_task == self.task);
}

pub fn decrementPreemptionDisable(self: *Context) void {
    const current_disable_count = self.preemption_disable_count;
    std.debug.assert(self.task.preemption_disable_count == current_disable_count);

    const executor = self.executor.?;
    std.debug.assert(executor.current_context == self);
    std.debug.assert(executor.current_task == self.task);

    if (current_disable_count == 1 and self.interrupt_disable_count == 0) {
        std.debug.assert(executor.interrupt_disable_count == 0);
        self.executor = null;
    }

    self.preemption_disable_count = current_disable_count - 1;
    self.task.preemption_disable_count = current_disable_count - 1;

    if (current_disable_count == 1 and self.task.preemption_skipped) {
        kernel.scheduler.maybePreempt(self);
    }
}

pub const InterruptContextRestore = struct {
    context: *Context,
    executor: *kernel.Executor,

    interrupt_disable_count: u32,
    preemption_disable_count: u32,

    pub fn exit(self: InterruptContextRestore) void {
        std.debug.assert(self.executor.current_context == self.context);

        std.debug.assert(self.context.interrupt_disable_count == self.executor.interrupt_disable_count);
        std.debug.assert(self.context.preemption_disable_count == self.executor.current_task.preemption_disable_count);

        self.context.interrupt_disable_count = self.interrupt_disable_count;
        self.executor.interrupt_disable_count = self.interrupt_disable_count;
        self.context.preemption_disable_count = self.preemption_disable_count;
        self.executor.current_task.preemption_disable_count = self.preemption_disable_count;

        if (self.interrupt_disable_count == 0 and self.preemption_disable_count == 0) self.context.executor = null;
    }
};

pub fn onInterruptEntry(self: *Context, executor: *kernel.Executor) InterruptContextRestore {
    std.debug.assert(!arch.interrupts.areEnabled());
    if (self.executor) |self_executor| {
        std.debug.assert(executor.current_context == self);
        std.debug.assert(self_executor == executor);
    }

    const restore: InterruptContextRestore = .{
        .context = self,
        .executor = executor,
        .interrupt_disable_count = executor.interrupt_disable_count,
        .preemption_disable_count = executor.current_task.preemption_disable_count,
    };

    const current_disable_count = self.interrupt_disable_count;

    self.interrupt_disable_count = current_disable_count + 1;
    executor.interrupt_disable_count = current_disable_count + 1;

    self.executor = executor;
    executor.current_context = self;

    return restore;
}

pub fn createNew(self: *Context, executor: *kernel.Executor) void {
    std.debug.assert(!arch.interrupts.areEnabled());
    std.debug.assert(executor.current_task.preemption_disable_count == 0);

    self.* = .{
        .executor = executor,
        .interrupt_disable_count = 1,
        .task = executor.current_task,
        .preemption_disable_count = 0,
    };

    executor.interrupt_disable_count = 1;
    executor.current_context = self;
}

pub fn getCurrent() *Context {
    arch.interrupts.disableInterrupts();

    const executor = arch.rawGetCurrentExecutor();

    if (executor.interrupt_disable_count == 0) arch.interrupts.enableInterrupts();

    return executor.current_context.?;
}

const std = @import("std");
const core = @import("core");
const arch = @import("arch");
const kernel = @import("kernel");

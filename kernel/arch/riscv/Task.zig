// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const cascade = @import("cascade");
const core = @import("core");
const std = @import("std");

const riscv = @import("riscv.zig");

const Task = @This();

/// Perform architecture specific task initialization.
///
/// This function is called very early during init so cannot use any kernel subsystems.
pub fn initialize(task: *cascade.Task) void {
    _ = task;
}

/// Get the current `Task`.
///
/// Supports being called with inter
pub inline fn getCurrent() *cascade.Task {
    return @ptrFromInt(riscv.registers.SupervisorScratch.read());
}

/// Set the current task.
///
/// Supports being called with interrupts and preemption enabled.
pub inline fn setCurrent(task: *cascade.Task) void {
    riscv.registers.SupervisorScratch.write(@intFromPtr(task));
}

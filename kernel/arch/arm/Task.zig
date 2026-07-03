// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const cascade = @import("cascade");
const core = @import("core");
const std = @import("std");

const arm = @import("arm.zig");

const Task = @This();

/// Perform architecture specific task initialization.
///
/// This function is called very early during init so cannot use any kernel subsystems.
pub fn initialize(_: *cascade.Task) void {}

/// Get the current `Task`.
///
/// Supports being called with interrupts and preemption enabled.
pub inline fn getCurrent() *cascade.Task {
    return @ptrFromInt(arm.registers.TPIDR_EL1.read());
}

/// Set the current task.
///
/// Supports being called with interrupts and preemption enabled.
pub inline fn setCurrent(task: *cascade.Task) void {
    arm.registers.TPIDR_EL1.write(@intFromPtr(task));
}

// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const x64 = @import("x64.zig");

const PerTask = @This();

/// A self pointer to the task used for GS relative accesses.
self_pointer: *cascade.Task,

/// Used to store the user rsp temporarily on syscall entry.
user_rsp_scratch: u64 = undefined,

pub inline fn from(task: *cascade.Task) *PerTask {
    return &task.arch_specific;
}

pub fn initializeTaskArchSpecific(task: *cascade.Task) void {
    const per_task: *PerTask = .from(task);
    per_task.* = .{
        .self_pointer = task,
    };
}

/// Get the current task.
///
/// Supports being called with interrupts and preemption enabled.
pub inline fn getCurrentTask() *cascade.Task {
    const static = struct {
        const self_pointer_offset_string = std.fmt.comptimePrint(
            "{d}",
            .{@offsetOf(cascade.Task, "arch_specific") + @offsetOf(PerTask, "self_pointer")},
        );
    };

    return asm ("mov %%gs:" ++ static.self_pointer_offset_string ++ ", %[current_task]"
        : [current_task] "=r" (-> *cascade.Task),
    );
}

/// Set the current task.
///
/// Supports being called with interrupts and preemption enabled.
pub inline fn setCurrentTask(task: *cascade.Task) void {
    x64.registers.GS_BASE.write(@intFromPtr(task));
}

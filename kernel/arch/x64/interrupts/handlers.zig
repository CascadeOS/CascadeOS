// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub fn perExecutorPeriodicHandler(current_task: *kernel.Task, _: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    x64.apic.eoi();
    kernel.entry.onPerExecutorPeriodic(current_task);
}

/// Handler for all unhandled interrupts.
///
/// Used during early initialization as well as during normal kernel operation.
pub fn unhandledInterrupt(_: *kernel.Task, interrupt_frame: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    core.panicFmt("unhandled interrupt\n{}", .{interrupt_frame}, null);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("../x64.zig");
const lib_x64 = @import("x64");
const InterruptFrame = x64.interrupts.InterruptFrame;

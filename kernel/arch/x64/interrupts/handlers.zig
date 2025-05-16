// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn nonMaskableInterruptHandler(_: *kernel.Task, interrupt_frame: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    if (kernel.debug.globals.panicking_executor.load(.acquire) == .none) {
        std.debug.panic("non-maskable interrupt\n{}", .{interrupt_frame});
    }

    // an executor is panicking so this NMI is a panic IPI
    kernel.arch.interrupts.disableInterruptsAndHalt();
}


pub fn flushRequestHandler(current_task: *kernel.Task, _: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    kernel.entry.onFlushRequest(current_task);
    // eoi after all current flush requests have been handled
    x64.apic.eoi();
}

pub fn perExecutorPeriodicHandler(current_task: *kernel.Task, _: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    // eoi before calling `onPerExecutorPeriodic` as we may get scheduled out and need to re-enable timer interrupts
    x64.apic.eoi();
    kernel.entry.onPerExecutorPeriodic(current_task);
}

/// Handler for all unhandled interrupts.
///
/// Used during early initialization as well as during normal kernel operation.
pub fn unhandledInterrupt(
    current_task: *kernel.Task,
    interrupt_frame: *InterruptFrame,
    _: ?*anyopaque,
    _: ?*anyopaque,
) void {
    const executor = current_task.state.running;
    std.debug.panic("unhandled interrupt on {}\n{}", .{ executor, interrupt_frame });
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("../x64.zig");
const lib_x64 = @import("x64");
const InterruptFrame = x64.interrupts.InterruptFrame;

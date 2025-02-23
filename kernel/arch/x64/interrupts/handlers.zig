// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub fn nonMaskableInterruptHandler(_: *kernel.Task, interrupt_frame: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    if (kernel.debug.globals.panicking_executor.load(.acquire) == .none) {
        std.debug.panic("non-maskable interrupt\n{}", .{interrupt_frame});
    }

    // an executor is panicking so this NMI is a panic IPI
    kernel.arch.interrupts.disableInterruptsAndHalt();
}

pub fn flushRequestHandler(current_task: *kernel.Task, _: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    const executor = current_task.state.running;

    while (executor.flush_requests.pop()) |node| {
        const request_node: *const kernel.vmm.FlushRequest.Node = @fieldParentPtr("node", node);
        request_node.request.performFlush(current_task);
    }

    x64.apic.eoi();
}

pub fn perExecutorPeriodicHandler(current_task: *kernel.Task, _: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    x64.apic.eoi();
    kernel.entry.onPerExecutorPeriodic(current_task);
}

/// Handler for all unhandled interrupts.
///
/// Used during early initialization as well as during normal kernel operation.
pub fn unhandledInterrupt(_: *kernel.Task, interrupt_frame: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    std.debug.panic("unhandled interrupt\n{}", .{interrupt_frame});
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("../x64.zig");
const lib_x64 = @import("x64");
const InterruptFrame = x64.interrupts.InterruptFrame;

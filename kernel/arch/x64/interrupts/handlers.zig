// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn nonMaskableInterruptHandler(
    _: *kernel.Task,
    interrupt_frame: InterruptFrame,
    _: ?*anyopaque,
    _: ?*anyopaque,
) void {
    if (kernel.debug.globals.panicking_executor.load(.acquire) == .none) {
        std.debug.panic("non-maskable interrupt\n{}", .{interrupt_frame});
    }

    // an executor is panicking so this NMI is a panic IPI
    kernel.arch.interrupts.disableInterruptsAndHalt();
}

pub fn pageFaultHandler(
    current_task: *kernel.Task,
    interrupt_frame: InterruptFrame,
    _: ?*anyopaque,
    _: ?*anyopaque,
) void {
    const faulting_address = lib_x64.registers.Cr2.readAddress();
    const error_code: lib_x64.PageFaultErrorCode = .fromErrorCode(interrupt_frame.arch.error_code);

    kernel.entry.onPageFault(current_task, .{
        .faulting_address = faulting_address,

        .access_type = if (error_code.write)
            .write
        else if (error_code.instruction_fetch)
            .execute
        else
            .read,

        .fault_type = if (error_code.present)
            .protection
        else
            .invalid,

        .context = if (error_code.user)
            .user
        else
            .kernel,
    }, interrupt_frame);
}

pub fn flushRequestHandler(current_task: *kernel.Task, _: InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    kernel.entry.onFlushRequest(current_task);
    // eoi after all current flush requests have been handled
    x64.apic.eoi();
}

pub fn perExecutorPeriodicHandler(current_task: *kernel.Task, _: InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    // eoi before calling `onPerExecutorPeriodic` as we may get scheduled out and need to re-enable timer interrupts
    x64.apic.eoi();
    kernel.entry.onPerExecutorPeriodic(current_task);
}

pub fn unhandledException(
    current_task: *kernel.Task,
    interrupt_frame: InterruptFrame,
    _: ?*anyopaque,
    _: ?*anyopaque,
) void {
    _ = current_task;

    switch (interrupt_frame.arch.context()) {
        .kernel => kernel.debug.interruptSourcePanic(
            interrupt_frame,
            "unhandled kernel exception: {s}",
            .{@tagName(interrupt_frame.arch.vector_number.interrupt)},
        ),
        .user => @panic("NOT IMPLEMENTED: unhandled exception in user mode"),
    }
}

/// Handler for all unhandled interrupts.
///
/// Used during early initialization as well as during normal kernel operation.
pub fn unhandledInterrupt(
    current_task: *kernel.Task,
    interrupt_frame: InterruptFrame,
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
const InterruptFrame = kernel.arch.interrupts.InterruptFrame;

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn nonMaskableInterruptHandler(
    _: *kernel.Task.Context,
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: ?*anyopaque,
    _: ?*anyopaque,
) void {
    if (kernel.debug.globals.panicking_executor.load(.acquire) == null) {
        std.debug.panic("non-maskable interrupt\n{f}", .{interrupt_frame});
    }

    // an executor is panicking so this NMI is a panic IPI
    x64.instructions.disableInterruptsAndHalt();
}

pub fn pageFaultHandler(
    context: *kernel.Task.Context,
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: ?*anyopaque,
    _: ?*anyopaque,
) void {
    const faulting_address = x64.registers.Cr2.readAddress();

    const arch_interrupt_frame: *const x64.interrupts.InterruptFrame = @ptrCast(@alignCast(interrupt_frame.arch_specific));
    const error_code: x64.paging.PageFaultErrorCode = .fromErrorCode(arch_interrupt_frame.error_code);

    kernel.entry.onPageFault(context, .{
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

        .environment = if (error_code.user)
            .{ .user = context.task().environment.user }
        else
            .kernel,
    }, interrupt_frame);
}

pub fn flushRequestHandler(
    context: *kernel.Task.Context,
    _: arch.interrupts.InterruptFrame,
    _: ?*anyopaque,
    _: ?*anyopaque,
) void {
    kernel.entry.onFlushRequest(context);
    // eoi after all current flush requests have been handled
    x64.apic.eoi();
}

pub fn perExecutorPeriodicHandler(
    context: *kernel.Task.Context,
    _: arch.interrupts.InterruptFrame,
    _: ?*anyopaque,
    _: ?*anyopaque,
) void {
    // eoi before calling `onPerExecutorPeriodic` as we may get scheduled out and need to re-enable timer interrupts
    x64.apic.eoi();
    kernel.entry.onPerExecutorPeriodic(context);
}

pub fn unhandledException(
    context: *kernel.Task.Context,
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: ?*anyopaque,
    _: ?*anyopaque,
) void {
    const arch_interrupt_frame: *const x64.interrupts.InterruptFrame = @ptrCast(@alignCast(interrupt_frame.arch_specific));
    switch (arch_interrupt_frame.environment(context)) {
        .kernel => kernel.debug.interruptSourcePanic(
            context,
            interrupt_frame,
            "unhandled kernel exception: {t}",
            .{arch_interrupt_frame.vector_number.interrupt},
        ),
        .user => @panic("NOT IMPLEMENTED: unhandled exception in user mode"),
    }
}

/// Handler for all unhandled interrupts.
///
/// Used during early initialization as well as during normal kernel operation.
pub fn unhandledInterrupt(
    context: *kernel.Task.Context,
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: ?*anyopaque,
    _: ?*anyopaque,
) void {
    const executor = context.executor.?;
    std.debug.panic("unhandled interrupt on {f}\n{f}", .{ executor, interrupt_frame });
}

const arch = @import("arch");
const kernel = @import("kernel");
const x64 = @import("../x64.zig");

const core = @import("core");
const std = @import("std");

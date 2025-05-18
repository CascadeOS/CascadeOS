// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn nonMaskableInterruptHandler(_: *kernel.Task, interrupt_frame: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    if (kernel.debug.globals.panicking_executor.load(.acquire) == .none) {
        std.debug.panic("non-maskable interrupt\n{}", .{interrupt_frame});
    }

    // an executor is panicking so this NMI is a panic IPI
    kernel.arch.interrupts.disableInterruptsAndHalt();
}

pub fn pageFaultHandler(current_task: *kernel.Task, interrupt_frame: *InterruptFrame, _: ?*anyopaque, _: ?*anyopaque) void {
    const faulting_address = lib_x64.registers.Cr2.readAddress();

    // now that the `faulting_address` has been captured, re-enable interrupts if they were enabled when the page fault
    // occurred
    current_task.decrementInterruptDisable();

    const error_code: lib_x64.PageFaultErrorCode = .fromErrorCode(interrupt_frame.error_code);

    var fault_type: kernel.mem.PageFaultDetails.FaultType = .invalid;
    if (error_code.present)
        fault_type = .protection
    else if (error_code.reserved_write)
        fault_type = .invalid;

    var access_type: kernel.mem.PageFaultDetails.AccessType = .read;
    if (error_code.write)
        access_type = .write
    else if (error_code.instruction_fetch)
        access_type = .execute;

    kernel.entry.onPageFault(current_task, .{
        .faulting_address = faulting_address,
        .access_type = access_type,
        .fault_type = fault_type,
        .source = if (error_code.user) .user else .kernel,
    });
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

// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const x64 = @import("../x64.zig");

pub fn nonMaskableInterruptHandler(
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    if (!kernel.debug.hasAnExecutorPanicked()) {
        std.debug.panic("non-maskable interrupt\n{f}", .{interrupt_frame});
    }

    // an executor is panicking so this NMI is a panic IPI
    x64.instructions.disableInterruptsAndHalt();
}

pub fn pageFaultHandler(
    interrupt_frame: arch.interrupts.InterruptFrame,
    state_before_interrupt: Task.Current.StateBeforeInterrupt,
) void {
    const faulting_address = x64.registers.Cr2.readAddress();

    const arch_interrupt_frame: *const x64.interrupts.InterruptFrame = .from(interrupt_frame);
    const error_code: x64.paging.PageFaultErrorCode = .fromErrorCode(arch_interrupt_frame.error_code);

    kernel.mem.onPageFault(.{
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

        .faulting_context = if (error_code.user)
            .user
        else
            .{
                .kernel = .{
                    .access_to_user_memory_enabled = state_before_interrupt.enable_access_to_user_memory_count != 0,
                },
            },
    }, interrupt_frame);
}

/// Handler for page faults that occur before the standard page fault handler is installed.
pub fn earlyPageFaultHandler(
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    const faulting_address = x64.registers.Cr2.readAddress();

    const arch_interrupt_frame: *const x64.interrupts.InterruptFrame = .from(interrupt_frame);
    const error_code: x64.paging.PageFaultErrorCode = .fromErrorCode(arch_interrupt_frame.error_code);

    switch (arch_interrupt_frame.contextSS()) {
        .kernel => kernel.debug.interruptSourcePanic(
            interrupt_frame,
            "kernel page fault @ {f} - {f}",
            .{ faulting_address, error_code },
        ),
        .user => unreachable, // a user execption is not possible during early initialization
    }
}

pub fn flushRequestHandler(
    _: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    kernel.mem.FlushRequest.processFlushRequests();
    // eoi after all current flush requests have been handled
    x64.apic.eoi();
}

pub fn perExecutorPeriodicHandler(
    _: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    // eoi before calling `maybePreempt` as we may get scheduled out and need to re-enable timer interrupts
    x64.apic.eoi();
    Task.Current.get().maybePreempt();
}

pub fn unhandledException(
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    const arch_interrupt_frame: *const x64.interrupts.InterruptFrame = .from(interrupt_frame);
    switch (arch_interrupt_frame.contextSS()) {
        .kernel => kernel.debug.interruptSourcePanic(
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
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    std.debug.panic(
        "unhandled interrupt on {f}\n{f}",
        .{ Task.Current.get().knownExecutor(), interrupt_frame },
    );
}

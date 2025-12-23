// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const x64 = @import("../x64.zig");

pub fn nonMaskableInterruptHandler(
    _: Task.Current,
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    if (!cascade.debug.hasAnExecutorPanicked()) {
        std.debug.panic("non-maskable interrupt\n{f}", .{interrupt_frame});
    }

    // an executor is panicking so this NMI is a panic IPI
    x64.instructions.disableInterruptsAndHalt();
}

pub fn pageFaultHandler(
    current_task: Task.Current,
    interrupt_frame: arch.interrupts.InterruptFrame,
    state_before_interrupt: Task.Current.StateBeforeInterrupt,
) void {
    const faulting_address = x64.registers.Cr2.readAddress();

    const arch_interrupt_frame: *const x64.interrupts.InterruptFrame = @ptrCast(@alignCast(interrupt_frame.arch_specific));
    const error_code: x64.paging.PageFaultErrorCode = .fromErrorCode(arch_interrupt_frame.error_code);

    cascade.mem.onPageFault(current_task, .{
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
            .{
                .user = .fromTask(current_task.task),
            }
        else
            .{
                .kernel = .{
                    .access_to_user_memory_enabled = state_before_interrupt.enable_access_to_user_memory_count != 0,
                },
            },
    }, interrupt_frame);
}

pub fn flushRequestHandler(
    current_task: Task.Current,
    _: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    cascade.mem.FlushRequest.processFlushRequests(current_task);
    // eoi after all current flush requests have been handled
    x64.apic.eoi();
}

pub fn perExecutorPeriodicHandler(
    current_task: Task.Current,
    _: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    // eoi before calling `onPerExecutorPeriodic` as we may get scheduled out and need to re-enable timer interrupts
    x64.apic.eoi();
    cascade.entry.onPerExecutorPeriodic(current_task);
}

pub fn unhandledException(
    current_task: Task.Current,
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    const arch_interrupt_frame: *const x64.interrupts.InterruptFrame = @ptrCast(@alignCast(interrupt_frame.arch_specific));
    switch (arch_interrupt_frame.context(current_task)) {
        .kernel => cascade.debug.interruptSourcePanic(
            current_task,
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
    current_task: Task.Current,
    interrupt_frame: arch.interrupts.InterruptFrame,
    _: Task.Current.StateBeforeInterrupt,
) void {
    const executor = current_task.knownExecutor();
    std.debug.panic("unhandled interrupt on {f}\n{f}", .{ executor, interrupt_frame });
}

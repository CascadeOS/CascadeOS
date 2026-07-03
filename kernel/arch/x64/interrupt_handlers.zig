// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");

const x64 = @import("x64.zig");

pub fn nonMaskableInterruptHandler(
    interrupt_frame: arch.Interrupt.Frame,
    _: cascade.Task.Current.StateBeforeInterrupt,
) void {
    if (!cascade.debug.hasAnExecutorPanicked()) {
        std.debug.panic("non-maskable interrupt\n{f}", .{interrupt_frame});
    }

    // an executor is panicking so this NMI is a panic IPI
    x64.Executor.current.disableInterruptsAndHalt();
}

pub fn pageFaultHandler(
    interrupt_frame: arch.Interrupt.Frame,
    state_before_interrupt: cascade.Task.Current.StateBeforeInterrupt,
) void {
    const faulting_address = x64.registers.Cr2.readAddress();

    const x64_interrupt_frame: *const x64.Interrupt.Frame = .from(interrupt_frame);
    const error_code: PageFaultErrorCode = .fromErrorCode(x64_interrupt_frame.error_code);

    cascade.mem.onPageFault(.{
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
                    .access_user_memory_enabled = state_before_interrupt.access_user_memory,
                },
            },
    }, interrupt_frame);
}

/// Handler for page faults that occur before the standard page fault handler is installed.
pub fn earlyPageFaultHandler(
    interrupt_frame: arch.Interrupt.Frame,
    _: cascade.Task.Current.StateBeforeInterrupt,
) void {
    const faulting_address = x64.registers.Cr2.readAddress();

    const x64_interrupt_frame: *const x64.Interrupt.Frame = .from(interrupt_frame);
    const error_code: PageFaultErrorCode = .fromErrorCode(x64_interrupt_frame.error_code);

    switch (x64_interrupt_frame.context()) {
        .kernel => cascade.debug.interruptSourcePanic(
            interrupt_frame,
            "kernel page fault @ {f} - {f}",
            .{ faulting_address, error_code },
        ),
        .user => unreachable, // a user exception is not possible during early initialization
    }
}

pub fn flushRequestHandler(
    _: arch.Interrupt.Frame,
    _: cascade.Task.Current.StateBeforeInterrupt,
) void {
    // eoi is called after this handler returns
    cascade.mem.FlushRequest.processFlushRequests();
}

pub fn perExecutorPeriodicHandler(
    _: arch.Interrupt.Frame,
    _: cascade.Task.Current.StateBeforeInterrupt,
) void {
    // eoi is called before this handler
    cascade.Task.Current.get().maybePreempt();
}

pub fn spuriousInterruptHandler(
    _: arch.Interrupt.Frame,
    _: cascade.Task.Current.StateBeforeInterrupt,
) void {
    // TODO: track occurrences of this, rather than panic
    @panic("spurious interrupt");
}

pub fn unhandledException(
    interrupt_frame: arch.Interrupt.Frame,
    _: cascade.Task.Current.StateBeforeInterrupt,
) void {
    const x64_interrupt_frame: *const x64.Interrupt.Frame = .from(interrupt_frame);
    switch (x64_interrupt_frame.context()) {
        .kernel => cascade.debug.interruptSourcePanic(
            interrupt_frame,
            "unhandled kernel exception: {t}",
            .{x64_interrupt_frame.vector_number.interrupt},
        ),
        .user => std.debug.panic("NOT IMPLEMENTED: unhandled exception in user mode\n{f}", .{interrupt_frame}),
    }
}

/// Handler for all unhandled interrupts.
///
/// Used during early initialization as well as during normal kernel operation.
pub fn unhandledInterrupt(
    interrupt_frame: arch.Interrupt.Frame,
    _: cascade.Task.Current.StateBeforeInterrupt,
) void {
    std.debug.panic(
        "unhandled interrupt on {f}\n{f}",
        .{ cascade.Task.Current.get().knownExecutor(), interrupt_frame },
    );
}

const PageFaultErrorCode = packed struct(u64) {
    /// When set, the page fault was caused by a page-protection violation.
    ///
    /// When not set, it was caused by a non-present page.
    present: bool,

    /// When set, the page fault was caused by a write access.
    ///
    /// When not set, it was caused by a read access.
    write: bool,

    /// When set, the page fault was caused while CPL = 3.
    user: bool,

    /// When set, one or more page directory entries contain reserved bits which are set to 1.
    ///
    /// This only applies when the PSE or PAE flags in CR4 are set to 1.
    reserved_write: bool,

    /// When set, the page fault was caused by an instruction fetch.
    ///
    /// This only applies when the No-Execute bit is supported and enabled.
    instruction_fetch: bool,

    /// When set, the page fault was caused by a protection-key violation.
    ///
    /// The PKRU register (for user-mode accesses) or PKRS MSR (for supervisor-mode accesses) specifies the protection
    /// key rights.
    protection_key: bool,

    /// When set, the page fault was caused by a shadow stack access.
    shadow_stack: bool,

    /// When set there is no translation for the linear address using HLAT paging.
    hlat: bool,

    _reserved1: u7,

    /// When set, the fault was due to an SGX violation.
    software_guard_exception: bool,

    _reserved2: u48,

    pub inline fn fromErrorCode(error_code: u64) PageFaultErrorCode {
        return @bitCast(error_code);
    }

    pub fn print(page_fault_error_code: PageFaultErrorCode, writer: *std.Io.Writer, indent: usize) !void {
        _ = indent;

        try writer.writeAll("PageFaultErrorCode{ ");

        if (!page_fault_error_code.present) {
            try writer.writeAll("Not Present }");
            return;
        }

        if (page_fault_error_code.user) {
            try writer.writeAll("User - ");
        } else {
            try writer.writeAll("Kernel - ");
        }

        if (page_fault_error_code.write) {
            try writer.writeAll("Write");
        } else {
            try writer.writeAll("Read");
        }

        if (page_fault_error_code.reserved_write) {
            try writer.writeAll("- Reserved Bit Set");
        }

        if (page_fault_error_code.instruction_fetch) {
            try writer.writeAll("- No Execute");
        }

        if (page_fault_error_code.instruction_fetch) {
            try writer.writeAll("- Protection Key");
        }

        if (page_fault_error_code.instruction_fetch) {
            try writer.writeAll("- Shadow Stack");
        }

        if (page_fault_error_code.hlat) {
            try writer.writeAll("- Hypervisor Linear Address Translation");
        }

        if (page_fault_error_code.instruction_fetch) {
            try writer.writeAll("- Software Guard Extension");
        }

        try writer.writeAll(" }");
    }

    pub inline fn format(page_fault_error_code: PageFaultErrorCode, writer: *std.Io.Writer) !void {
        return page_fault_error_code.print(writer, 0);
    }
};

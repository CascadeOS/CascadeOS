// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.init_x64);

const x64 = @import("x64.zig");

var early_output_serial_port: ?x64.SerialPort = null;

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    early_output_serial_port = x64.SerialPort.init(.COM1, .Baud115200);
}

/// Acquire a writer for the early output setup by `setupEarlyOutput`.
pub fn getEarlyOutput() ?x64.SerialPort.Writer {
    return if (early_output_serial_port) |output| output.writer() else null;
}

var bootstrap_double_fault_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;
var bootstrap_non_maskable_interrupt_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;

/// Prepares the provided `Cpu` for the bootstrap CPU.
pub fn prepareBootstrapCpu(
    bootstrap_cpu: *kernel.Cpu,
) void {
    bootstrap_cpu.arch = .{
        .double_fault_stack = kernel.Stack.fromRange(
            core.VirtualRange.fromSlice(u8, &bootstrap_double_fault_stack),
            core.VirtualRange.fromSlice(u8, &bootstrap_double_fault_stack),
        ),
        .non_maskable_interrupt_stack = kernel.Stack.fromRange(
            core.VirtualRange.fromSlice(u8, &bootstrap_non_maskable_interrupt_stack),
            core.VirtualRange.fromSlice(u8, &bootstrap_non_maskable_interrupt_stack),
        ),
    };
}

/// Load the provided `Cpu` as the current CPU.
pub fn loadCpu(cpu: *kernel.Cpu) void {
    const arch = &cpu.arch;

    arch.gdt.load();

    arch.tss.setInterruptStack(
        @intFromEnum(x64.interrupts.InterruptStackSelector.double_fault),
        arch.double_fault_stack.stack_pointer,
    );
    arch.tss.setInterruptStack(
        @intFromEnum(x64.interrupts.InterruptStackSelector.non_maskable_interrupt),
        arch.non_maskable_interrupt_stack.stack_pointer,
    );

    arch.gdt.setTss(&arch.tss);

    x64.interrupts.init.loadIdt();

    x64.KERNEL_GS_BASE.write(@intFromPtr(cpu));
}

/// Capture any system information that is required for the architecture.
///
/// For example, on x64 this should capture the CPUID information.
pub fn captureSystemInformation() !void {
    log.debug("capturing cpuid information", .{});
    try x64.info.cpu_id.capture();
}

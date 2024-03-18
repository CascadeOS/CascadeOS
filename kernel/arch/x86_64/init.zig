// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.init_x86_64);

const x86_64 = @import("x86_64.zig");

var early_output_serial_port: ?x86_64.SerialPort = null;

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    early_output_serial_port = x86_64.SerialPort.init(.COM1, .Baud115200);
}

/// Acquire a writer for the early output setup by `setupEarlyOutput`.
pub fn getEarlyOutput() ?x86_64.SerialPort.Writer {
    return if (early_output_serial_port) |output| output.writer() else null;
}

/// Prepares the provided `Cpu` for the bootstrap CPU.
pub fn prepareBootstrapCpu(
    bootstrap_cpu: *kernel.Cpu,
) void {
    bootstrap_cpu.arch = .{};
}

/// Load the provided `Cpu` as the current CPU.
pub fn loadCpu(cpu: *kernel.Cpu) void {
    const arch = &cpu.arch;

    arch.gdt.load();

    arch.gdt.setTss(&arch.tss);

    x86_64.interrupts.init.loadIdt();

    x86_64.KERNEL_GS_BASE.write(@intFromPtr(cpu));
}

/// Capture any system information that is required for the architecture.
///
/// For example, on x86_64 this should capture the CPUID information.
pub fn captureSystemInformation() void {
    log.debug("capturing cpuid information", .{});
    x86_64.info.cpu_id.capture() catch core.panic("cpuid is not supported");
}

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

    x64.interrupts.init.loadIdt();

    x64.KERNEL_GS_BASE.write(@intFromPtr(cpu));
}

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const aarch64 = @import("aarch64.zig");
const Uart = @import("Uart.zig");

const log = kernel.debug.log.scoped(.init_aarch64);

pub const EarlyOutputWriter = Uart.Writer;
var early_output_uart: ?Uart = null;

pub fn setupEarlyOutput() void {
    early_output_uart = Uart.init(0x09000000);
}

pub fn getEarlyOutputWriter() ?Uart.Writer {
    return if (early_output_uart) |output| output.writer() else null;
}

pub fn prepareBootstrapProcessor(bootstrap_processor: *kernel.Processor) void {
    _ = bootstrap_processor;
}

pub fn prepareProcessor(
    processor: *kernel.Processor,
    processor_descriptor: kernel.boot.ProcessorDescriptor,
) void {
    _ = processor;
    _ = processor_descriptor;
}

pub fn loadProcessor(processor: *kernel.Processor) void {
    aarch64.registers.TPIDR_EL1.write(@intFromPtr(processor));
}

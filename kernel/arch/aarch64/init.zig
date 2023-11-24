// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const aarch64 = @import("aarch64.zig");

const log = kernel.log.scoped(.init);

pub const EarlyOutputWriter = aarch64.Uart.Writer;
var early_output_uart: ?aarch64.Uart = null;

pub fn setupEarlyOutput() void {
    // TODO: Use the device tree to find the UART base address https://github.com/CascadeOS/CascadeOS/issues/24
    early_output_uart = aarch64.Uart.init(0x09000000);
}

pub fn getEarlyOutputWriter() ?aarch64.Uart.Writer {
    return if (early_output_uart) |output| output.writer() else null;
}

pub fn prepareBootstrapProcessor(bootstrap_processor: *kernel.Processor) void {
    _ = bootstrap_processor;
}

pub fn prepareProcessor(processor: *kernel.Processor) void {
    _ = processor;
}

pub fn loadProcessor(processor: *kernel.Processor) void {
    aarch64.registers.TPIDR_EL1.write(@intFromPtr(processor));
}

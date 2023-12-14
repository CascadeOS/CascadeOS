// SPDX-License-Identifier: MIT

const aarch64 = @import("aarch64.zig");
const core = @import("core");
const info = kernel.info;
const kernel = @import("kernel");
const Processor = kernel.Processor;
const registers = aarch64.registers;
const std = @import("std");
const Uart = aarch64.Uart;

const log = kernel.debug.log.scoped(.init);

pub const EarlyOutputWriter = Uart.Writer;
var early_output_uart: ?Uart = null; // TODO: Put in init_data section

pub fn setupEarlyOutput() linksection(info.init_code) void {
    early_output_uart = Uart.init(0x09000000);
}

pub fn getEarlyOutputWriter() ?Uart.Writer { // TODO: Put in init_code section
    return if (early_output_uart) |output| output.writer() else null;
}

pub fn prepareBootstrapProcessor(bootstrap_processor: *Processor) linksection(info.init_code) void {
    _ = bootstrap_processor;
}

pub fn prepareProcessor(processor: *Processor) linksection(info.init_code) void {
    _ = processor;
}

pub fn loadProcessor(processor: *Processor) linksection(info.init_code) void {
    registers.TPIDR_EL1.write(@intFromPtr(processor));
}

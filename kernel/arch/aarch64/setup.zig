// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const aarch64 = @import("aarch64.zig");

const log = kernel.log.scoped(.setup_aarch64);

pub const EarlyOutputWriter = aarch64.Uart.Writer;
var early_output_uart: aarch64.Uart = undefined;

pub fn setupEarlyOutput() void {
    // TODO: Use the device tree to find the UART base address.
    early_output_uart = aarch64.Uart.init(0x09000000);
}

pub inline fn getEarlyOutputWriter() aarch64.Uart.Writer {
    return early_output_uart.writer();
}

pub fn earlyArchInitialization() void {
    core.panic("UNIMPLEMENTED `earlyArchInitialization`"); // TODO: Implement `earlyArchInitialization`.
}

pub fn captureSystemInformation() void {
    core.panic("UNIMPLEMENTED `captureSystemInformation`"); // TODO: Implement `captureSystemInformation`.
}

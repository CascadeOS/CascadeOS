// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const aarch64 = @import("aarch64.zig");

const limine = kernel.spec.limine;
const log = kernel.log.scoped(.setup_aarch64);

/// Entry point.
export fn _start() callconv(.Naked) noreturn {
    @call(.never_inline, kernel.setup.setup, .{});
    @panic("setup returned");
}

pub const EarlyOutputWriter = aarch64.Uart.Writer;
var early_output_uart: aarch64.Uart = undefined;

pub fn setupEarlyOutput() void {
    // TODO: Use the device tree to find the UART base address.

    // TODO: It would be better if the boards could be integrated with the arch, so only valid ones for that arch are possible.
    switch (kernel.info.board.?) {
        .virt => early_output_uart = aarch64.Uart.init(0x09000000),
    }
}

pub inline fn getEarlyOutputWriter() aarch64.Uart.Writer {
    return early_output_uart.writer();
}

pub fn earlyArchInitialization() void {
    @panic("UNIMPLEMENTED `earlyArchInitialization`"); // TODO: Implement `earlyArchInitialization`.
}

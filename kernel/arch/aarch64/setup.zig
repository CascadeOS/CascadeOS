// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const aarch64 = @import("aarch64.zig");

const limine = kernel.spec.limine;

/// Entry point.
export fn _start() callconv(.Naked) noreturn {
    @call(.never_inline, kernel.setup.setup, .{});
    @panic("setup returned");
}

var early_output_uart: aarch64.UART = undefined;

pub fn setupEarlyOutput() void {
    // TODO: Use the device tree to find the UART base address.

    // TODO: It would be better if the boards could be integrated with the arch,
    // so only valid ones for that arch are possible.
    switch (kernel.info.board.?) {
        .virt => early_output_uart = aarch64.UART.init(0x09000000),
    }
    kernel.setPanicFunction(simplePanic);
}

pub inline fn getEarlyOutputWriter() aarch64.UART.Writer {
    return early_output_uart.writer();
}

/// Prints the panic message then disables interrupts and halts.
fn simplePanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = ret_addr;
    _ = stack_trace;

    early_output_uart.writer().print("\nPANIC: {s}\n", .{msg}) catch unreachable;

    while (true) {
        aarch64.instructions.disableInterruptsAndHalt();
    }
}

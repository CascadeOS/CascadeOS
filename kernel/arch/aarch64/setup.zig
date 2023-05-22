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

var uart: aarch64.UART = undefined;

pub fn setupEarlyOutput() void {
    // TODO: Use the device tree to find the UART base address.

    // TODO: It would be better if the boards could be integrated with the arch,
    // so only valid ones for that arch are possible.
    switch (kernel.info.board.?) {
        .virt => uart = aarch64.UART.init(0x09000000),
    }
    kernel.setPanicFunction(simplePanic);
}

pub fn earlyOutputRaw(str: []const u8) void {
    uart.writer().writeAll(str) catch unreachable;
}

/// Logging function for early boot only.
pub fn earlyLogFn(
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: kernel.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    const writer = uart.writer();

    const scopeAndLevelText = comptime kernel.log.formatScopeAndLevel(message_level, scope);
    writer.writeAll(scopeAndLevelText) catch unreachable;

    const user_fmt = comptime if (format.len != 0 and format[format.len - 1] == '\n') format else format ++ "\n";
    writer.print(user_fmt, args) catch unreachable;
}

/// Prints the panic message then disables interrupts and halts.
fn simplePanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = ret_addr;
    _ = stack_trace;

    uart.writer().print("\nPANIC: {s}\n", .{msg}) catch unreachable;

    while (true) {
        aarch64.instructions.disableInterruptsAndHalt();
    }
}

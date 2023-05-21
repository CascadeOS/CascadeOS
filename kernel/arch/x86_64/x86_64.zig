// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub const port = @import("port.zig");
pub const serial = @import("serial.zig");

comptime {
    // make sure the entry points are referenced
    _ = @import("entry.zig");
}

/// Disable interrupts and put the CPU to sleep.
pub fn disableInterruptsAndHalt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

/// Logging function for early boot only.
pub fn earlyLogFn(
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: kernel.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    _ = args;
    _ = format;
    _ = message_level;
    _ = scope;
    @panic("UNIMPLEMENTED"); // TODO: implement earlyLogFn
pub inline fn pause() void {
    asm volatile ("pause");
}


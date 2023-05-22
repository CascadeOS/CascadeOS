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

pub fn earlyOutputRaw(str: []const u8) void {
    _ = str;
    @panic("UNIMPLEMENTED"); // TODO: implement earlyOutputRaw
}

pub fn setupEarlyOutput() void {
    @panic("UNIMPLEMENTED"); // TODO: implement setupEarlyOutput
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
}

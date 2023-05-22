// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const aarch64 = @import("aarch64.zig");

const limine = kernel.spec.limine;

fn setup() void {
    @panic("UNIMPLEMENTED"); // TODO: implement initial system setup
}

/// Entry point.
export fn _start() callconv(.Naked) noreturn {
    @call(.never_inline, setup, .{});
    @panic("setup returned");
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

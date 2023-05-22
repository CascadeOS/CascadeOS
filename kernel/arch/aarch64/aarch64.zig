// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub const instructions = @import("instructions.zig");
comptime {
    // make sure the entry points are referenced
    _ = @import("entry.zig");
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
}
pub const public = struct {
    pub const disableInterruptsAndHalt = instructions.disableInterruptsAndHalt;
};

// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub const aarch64 = @import("aarch64/aarch64.zig");
pub const x86_64 = @import("x86_64/x86_64.zig");

pub const current: type = switch (kernel.info.arch) {
    .aarch64 => aarch64,
    .x86_64 => x86_64,
};

comptime {
    // ensure any architecture specific code is referenced
    _ = current;
}

pub inline fn disableInterruptsAndHalt() noreturn {
    callCurrent(noreturn, "disableInterruptsAndHalt", .{});
}

inline fn callCurrent(comptime ReturnType: type, comptime name: []const u8, args: anytype) ReturnType {
    if (!@hasDecl(current, name)) {
        // TODO: should this be a compile error?
        std.debug.panicExtra(null, @returnAddress(), comptime @tagName(kernel.info.arch) ++ " has not implemented `" ++ name ++ "`", .{});
    }
    return @call(.auto, @field(current, name), args);
}

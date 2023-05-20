// SPDX-License-Identifier: MIT

const std = @import("std");

pub const arch = @import("arch/arch.zig");
pub const info = @import("info.zig");

comptime {
    _ = arch.current;
}

export fn _start() callconv(.Naked) void {
    while (true) {}
}

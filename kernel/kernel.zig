// SPDX-License-Identifier: MIT

const std = @import("std");

pub const info = @import("info.zig");

export fn _start() callconv(.Naked) void {
    while (true) {}
}

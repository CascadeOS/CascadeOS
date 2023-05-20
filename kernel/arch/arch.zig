// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub const x86_64 = @import("x86_64/x86_64.zig");

pub const current = switch (kernel.info.arch) {
    .x86_64 => x86_64,
    else => |arch| @compileError("unsupported architecture " ++ @tagName(arch)),
};

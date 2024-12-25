// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>
pub const arch = @import("arch/arch.zig");

export fn _start() callconv(.C) noreturn {
    while (true) {}
}

const std = @import("std");

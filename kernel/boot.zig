// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

export fn _start() callconv(.C) noreturn {
    @call(.never_inline, @import("init.zig").kernelInit, .{});
    core.panic("`init.kernelInit` returned");
}

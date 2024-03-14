// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub usingnamespace @import("lib_x86_64");

pub const init = @import("init.zig");
pub const SerialPort = @import("SerialPort.zig");

comptime {
    if (@import("cascade_target").arch != .x86_64) {
        @compileError("x86_64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

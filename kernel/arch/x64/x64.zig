// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const lib_x64 = @import("lib_x64");
pub usingnamespace lib_x64;

pub const ArchCpu = @import("ArchCpu.zig");
pub const init = @import("init.zig");
pub const paging = @import("paging.zig");
pub const SerialPort = @import("SerialPort.zig");

comptime {
    if (@import("cascade_target").arch != .x64) {
        @compileError("x64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub usingnamespace @import("lib_aarch64");

pub const Uart = @import("Uart.zig");

comptime {
    if (@import("cascade_target").arch != .aarch64) {
        @compileError("aarch64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

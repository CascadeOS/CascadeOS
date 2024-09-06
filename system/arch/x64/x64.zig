// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const interrupts = @import("interrupts.zig");
pub const PerExecutor = @import("PerExecutor.zig");

pub const arch_interface = struct {
    pub const PerExecutor = @import("PerExecutor.zig");

    pub const interrupts = @import("interrupts.zig");

    pub const paging = struct {
        pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);
    };

    pub const init = @import("init.zig");
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const lib_x64 = @import("lib_x64");

comptime {
    if (@import("cascade_target").arch != .x64) {
        @compileError("x64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

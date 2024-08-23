// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const arch_interface = struct {
    pub const PerExecutor = @import("PerExecutor.zig");

    pub const interrupts = struct {
        pub const disableInterruptsAndHalt = lib_x64.instructions.disableInterruptsAndHalt;
        pub const disableInterrupts = lib_x64.instructions.disableInterrupts;
    };

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

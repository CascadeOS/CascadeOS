// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const arch_interface = struct {
    pub const PerExecutor = struct {};

    pub const interrupts = struct {
        pub const disableInterruptsAndHalt = lib_arm64.instructions.disableInterruptsAndHalt;
        pub const disableInterrupts = lib_arm64.instructions.disableInterrupts;

        pub const ArchInterruptContext = struct {};
    };

    pub const paging = struct {
        pub const standard_page_size = core.Size.from(4, .kib);
        pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);
    };

    pub const init = @import("init.zig");
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const lib_arm64 = @import("lib_arm64");

comptime {
    if (@import("cascade_target").arch != .arm64) {
        @compileError("arm64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

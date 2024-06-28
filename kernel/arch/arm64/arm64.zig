// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const lib_arm64 = @import("lib_arm64");
pub usingnamespace lib_arm64;

pub const init = @import("init.zig");
pub const interrupts = @import("interrupts.zig");

/// Get the current CPU.
///
/// Assumes that `init.loadCpu()` has been called on the currently running CPU.
pub inline fn getCpu() *kernel.Cpu {
    return @ptrFromInt(lib_arm64.TPIDR_EL1.read());
}

comptime {
    if (@import("cascade_target").arch != .arm64) {
        @compileError("arm64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

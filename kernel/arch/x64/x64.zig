// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const lib_x64 = @import("lib_x64");
pub usingnamespace lib_x64;

pub const apic = @import("apic.zig");
pub const ArchCpu = @import("ArchCpu.zig");
pub const hpet = @import("hpet.zig");
pub const info = @import("info.zig");
pub const init = @import("init.zig");
pub const interrupts = @import("interrupts.zig");
pub const paging = @import("paging.zig");
pub const scheduling = @import("scheduling.zig");
pub const SerialPort = @import("SerialPort.zig");
pub const tsc = @import("tsc.zig");

/// Get the current CPU.
///
/// Assumes that `init.loadCpu()` has been called on the currently running CPU.
pub inline fn getCpu() *kernel.Cpu {
    return @ptrFromInt(lib_x64.KERNEL_GS_BASE.read());
}

comptime {
    if (@import("cascade_target").arch != .x64) {
        @compileError("x64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

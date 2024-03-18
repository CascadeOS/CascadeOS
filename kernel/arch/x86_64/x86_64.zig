// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const lib_x86_64 = @import("lib_x86_64");
pub usingnamespace lib_x86_64;

pub const ArchCpu = @import("ArchCpu.zig");
pub const info = @import("info.zig");
pub const init = @import("init.zig");
pub const interrupts = @import("interrupts.zig");
pub const paging = @import("paging.zig");
pub const SerialPort = @import("SerialPort.zig");

/// Get the current CPU.
///
/// Assumes that `init.loadCpu()` has been called on the currently running CPU.
///
/// Asserts that interrupts are disabled.
pub inline fn getCpu() *kernel.Cpu {
    core.debugAssert(!lib_x86_64.interruptsEnabled());
    return @ptrFromInt(lib_x86_64.KERNEL_GS_BASE.read());
}

comptime {
    if (@import("cascade_target").arch != .x86_64) {
        @compileError("x86_64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

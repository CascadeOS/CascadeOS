// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const hpet = @import("hpet.zig");
pub const info = @import("info.zig");
pub const init = @import("init.zig");
pub const interrupts = @import("interrupts.zig");
pub const paging = @import("paging.zig");
pub const PerExecutor = @import("PerExecutor.zig");
pub const tsc = @import("tsc.zig");

/// Issues an architecture specific hint to the CPU that we are spinning in a loop.
pub const spinLoopHint = lib_x64.instructions.pause;

/// Get the current `Executor`.
///
/// Assumes that `init.loadExecutor()` has been called on the currently running CPU.
///
/// It is the callers responsibility to ensure that the current task is not re-scheduled onto another executor.
pub inline fn getCurrentExecutor() *kernel.Executor {
    return @ptrFromInt(lib_x64.registers.KERNEL_GS_BASE.read());
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const lib_x64 = @import("lib_x64");

comptime {
    if (@import("cascade_target").arch != .x64) {
        @compileError("x64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

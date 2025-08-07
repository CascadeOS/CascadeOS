// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const interface = @import("interface.zig");

pub const interrupts = @import("interrupts.zig");
pub const paging = @import("paging.zig");
pub const PerExecutor = @import("PerExecutor.zig");
pub const scheduling = @import("scheduling.zig");

pub const init = @import("init.zig");

/// Get the current `Executor`.
///
/// Assumes that `init.loadExecutor()` has been called on the currently running CPU.
pub fn getCurrentExecutor() *kernel.Executor {
    return @ptrFromInt(lib_riscv.registers.SupervisorScratch.read());
}

pub const spinLoopHint = lib_riscv.instructions.pause;

const kernel = @import("kernel");

const lib_riscv = @import("riscv");
const std = @import("std");

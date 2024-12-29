// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const info = @import("info.zig");
pub const interrupts = @import("interrupts.zig");
pub const paging = @import("paging.zig");
pub const PerExecutor = @import("PerExecutor.zig");

pub const init = @import("init.zig");

/// Get the current `Executor`.
///
/// Assumes that `init.loadExecutor()` has been called on the currently running CPU.
pub inline fn getCurrentExecutor() *kernel.Executor {
    return @ptrFromInt(lib_x64.registers.KERNEL_GS_BASE.read());
}

const std = @import("std");
const kernel = @import("kernel");
const lib_x64 = @import("x64");

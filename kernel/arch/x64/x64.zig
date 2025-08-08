// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const interface = @import("interface.zig");

pub const apic = @import("apic.zig");
pub const config = @import("config.zig");
pub const hpet = @import("hpet.zig");
pub const info = @import("info.zig");
pub const interrupts = @import("interrupts/interrupts.zig");
pub const ioapic = @import("ioapic.zig");
pub const paging = @import("paging.zig");
pub const PerExecutor = @import("PerExecutor.zig");
pub const scheduling = @import("scheduling.zig");
pub const tsc = @import("tsc.zig");

pub const init = @import("init.zig");

/// Get the current `Executor`.
///
/// Assumes that `init.loadExecutor()` has been called on the currently running CPU.
pub inline fn getCurrentExecutor() *kernel.Executor {
    return @ptrFromInt(lib_x64.registers.KERNEL_GS_BASE.read());
}

pub const spinLoopHint = lib_x64.instructions.pause;
pub const halt = lib_x64.instructions.halt;

const arch = @import("arch");
const kernel = @import("kernel");

const lib_x64 = @import("x64");
const std = @import("std");

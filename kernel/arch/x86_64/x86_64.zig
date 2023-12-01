// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

comptime {
    // make sure any interrupt handlers are referenced
    _ = interrupts;
}

pub const ArchProcessor = @import("ArchProcessor.zig");
pub const cpuid = @import("cpuid.zig");
pub const Gdt = @import("Gdt.zig").Gdt;
pub const info = @import("info.zig");
pub const init = @import("init.zig");
pub const instructions = @import("instructions.zig");
pub const interrupts = @import("interrupts/interrupts.zig");
pub const paging = @import("paging/paging.zig");
pub const registers = @import("registers.zig");
pub const serial = @import("serial.zig");
pub const Tss = @import("Tss.zig").Tss;

pub inline fn getProcessor() *kernel.Processor {
    return @ptrFromInt(registers.KERNEL_GS_BASE.read());
}

pub const PrivilegeLevel = enum(u2) {
    /// Kernel
    ring0 = 0,

    /// Unused
    ring1 = 1,

    /// Unused
    ring2 = 2,

    /// Userspace
    ring3 = 3,
};

pub const spinLoopHint = instructions.pause;

pub const switchToStack = instructions.switchToStack;

comptime {
    if (kernel.info.arch != .x86_64) {
        @compileError("x86_64 implementation has been referenced when building " ++ @tagName(kernel.info.arch));
    }
}

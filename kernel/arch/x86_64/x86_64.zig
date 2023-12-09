// SPDX-License-Identifier: MIT

const core = @import("core");
const info = kernel.info;
const kernel = @import("kernel");
const Processor = kernel.Processor;
const Stack = kernel.Stack;
const std = @import("std");
const VirtualAddress = kernel.VirtualAddress;

comptime {
    // make sure any interrupt handlers are referenced
    _ = interrupts;
}

pub const arch_info = @import("arch_info.zig");
pub const ArchProcessor = @import("ArchProcessor.zig");
pub const cpuid = @import("cpuid.zig");
pub const Gdt = @import("Gdt.zig").Gdt;
pub const init = @import("init.zig");
pub const instructions = @import("instructions.zig");
pub const interrupts = @import("interrupts/interrupts.zig");
pub const paging = @import("paging/paging.zig");
pub const registers = @import("registers.zig");
pub const scheduling = @import("scheduling.zig");
pub const serial = @import("serial.zig");
pub const Tss = @import("Tss.zig").Tss;

pub inline fn getProcessor() *Processor {
    return @ptrFromInt(registers.KERNEL_GS_BASE.read());
}

pub inline fn earlyGetProcessor() ?*Processor {
    return @ptrFromInt(registers.KERNEL_GS_BASE.read());
}

pub const PrivilegeLevel = enum(u2) {
    /// Kernel
    kernel = 0,

    /// Unused
    _unused1 = 1,

    /// Unused
    _unused2 = 2,

    /// Userspace
    user = 3,
};

pub const spinLoopHint = instructions.pause;

comptime {
    if (info.arch != .x86_64) {
        @compileError("x86_64 implementation has been referenced when building " ++ @tagName(info.arch));
    }
}

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const x86_64 = @import("lib_x86_64");
pub usingnamespace x86_64;

comptime {
    // make sure any interrupt handlers are referenced
    _ = &interrupts;
}

pub const apic = @import("apic.zig");
pub const arch_info = @import("arch_info.zig");
pub const ArchProcessor = @import("ArchProcessor.zig");
pub const hpet = @import("hpet.zig");
pub const init = @import("init.zig");
pub const interrupts = @import("interrupts/interrupts.zig");
pub const paging = @import("paging.zig");
pub const scheduling = @import("scheduling.zig");
pub const tsc = @import("tsc.zig");

pub inline fn getProcessor() *kernel.Processor {
    return @ptrFromInt(x86_64.KERNEL_GS_BASE.read());
}

pub inline fn earlyGetProcessor() ?*kernel.Processor {
    return @ptrFromInt(x86_64.KERNEL_GS_BASE.read());
}

comptime {
    if (kernel.info.arch != .x86_64) {
        @compileError("x86_64 implementation has been referenced when building " ++ @tagName(kernel.info.arch));
    }
}

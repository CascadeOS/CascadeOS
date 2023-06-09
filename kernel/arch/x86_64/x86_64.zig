// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

comptime {
    // make sure any interrupt handlers are referenced
    _ = interrupts;
}

pub const cpuid = @import("cpuid.zig");
pub const Gdt = @import("Gdt.zig").Gdt;
pub const info = @import("info.zig");
pub const instructions = @import("instructions.zig");
pub const interrupts = @import("interrupts/interrupts.zig");
pub const paging = @import("paging/paging.zig");
pub const registers = @import("registers.zig");
pub const serial = @import("serial.zig");
pub const setup = @import("setup.zig");
pub const Tss = @import("Tss.zig").Tss;

pub const PrivilegeLevel = enum(u2) {
    /// Privilege-level 0 (most privilege): This level is used by critical system-software
    /// components that require direct access to, and control over, all processor and system
    /// resources. This can include BIOS, memory-management functions, and interrupt handlers.
    ring0 = 0,

    /// Privilege-level 1 (moderate privilege): This level is used by less-critical system-
    /// software services that can access and control a limited scope of processor and system
    /// resources. Software running at these privilege levels might include some device drivers
    /// and library routines. The actual privileges of this level are defined by the
    /// operating system.
    ring1 = 1,

    /// Privilege-level 2 (moderate privilege): Like level 1, this level is used by
    /// less-critical system-software services that can access and control a limited scope of
    /// processor and system resources. The actual privileges of this level are defined by the
    /// operating system.
    ring2 = 2,

    /// Privilege-level 3 (least privilege): This level is used by application software.
    /// Software running at privilege-level 3 is normally prevented from directly accessing
    /// most processor and system resources. Instead, applications request access to the
    /// protected processor and system resources by calling more-privileged service routines
    /// to perform the accesses.
    ring3 = 3,
};

pub const spinLoopHint = instructions.pause;

comptime {
    if (kernel.info.arch != .x86_64) {
        @compileError("x86_64 implementation has been referenced when building " ++ @tagName(kernel.info.arch));
    }
}

// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;
const addr = cascade.addr;

const x64 = @import("x64.zig");

/// The Task State Segment structure.
pub const Tss = extern struct {
    _reserved_1: u32 align(1) = 0,

    /// Stack pointers (RSP) for privilege levels 0-2.
    privilege_stack_table: [3]addr.Virtual.Kernel align(1) = undefined,

    _reserved_2: u64 align(1) = 0,

    /// Interrupt stack table (IST) pointers.
    interrupt_stack_table: [7]addr.Virtual.Kernel align(1) = undefined,

    _reserved_3: u64 align(1) = 0,

    _reserved_4: u16 align(1) = 0,

    /// The 16-bit offset to the I/O permission bit map from the 64-bit TSS base.
    iomap_base: u16 align(1) = 0,

    /// Sets the stack for the given stack selector.
    pub fn setInterruptStack(
        tss: *Tss,
        stack_selector: x64.interrupts.InterruptStackSelector,
        stack_pointer: addr.Virtual.Kernel,
    ) void {
        tss.interrupt_stack_table[@intFromEnum(stack_selector)] = stack_pointer;
    }

    /// Sets the stack for the given privilege level.
    pub fn setPrivilegeStack(
        tss: *Tss,
        privilege_level: x64.PrivilegeLevel,
        stack_pointer: addr.Virtual.Kernel,
    ) void {
        if (core.is_debug) std.debug.assert(privilege_level != .ring3);
        tss.privilege_stack_table[@intFromEnum(privilege_level)] = stack_pointer;
    }

    comptime {
        core.testing.expectSize(Tss, .from(104, .byte));
    }
};

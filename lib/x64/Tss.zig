// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// The Task State Segment structure.
pub const Tss = extern struct {
    _reserved_1: u32 align(1) = 0,

    /// Stack pointers (RSP) for privilege levels 0-2.
    privilege_stack_table: [3]core.VirtualAddress align(1) = [_]core.VirtualAddress{core.VirtualAddress.zero} ** 3,

    _reserved_2: u64 align(1) = 0,

    /// Interrupt stack table (IST) pointers.
    interrupt_stack_table: [7]core.VirtualAddress align(1) = [_]core.VirtualAddress{core.VirtualAddress.zero} ** 7,

    _reserved_3: u64 align(1) = 0,

    _reserved_4: u16 align(1) = 0,

    /// The 16-bit offset to the I/O permission bit map from the 64-bit TSS base.
    iomap_base: u16 align(1) = 0,

    /// Sets the stack for the given stack selector.
    pub fn setInterruptStack(
        self: *Tss,
        stack_selector: u3,
        stack_pointer: core.VirtualAddress,
    ) void {
        self.interrupt_stack_table[stack_selector] = stack_pointer;
    }

    /// Sets the stack for the given privilege level.
    pub fn setPrivilegeStack(
        self: *Tss,
        privilege_level: x64.PrivilegeLevel,
        stack_pointer: core.VirtualAddress,
    ) void {
        std.debug.assert(privilege_level != .ring3);
        self.privilege_stack_table[@intFromEnum(privilege_level)] = stack_pointer;
    }

    comptime {
        core.testing.expectSize(@This(), 104);
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const core = @import("core");
const std = @import("std");

const x64 = @import("x64");

// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

const InterruptStackSelector = x86_64.interrupts.InterruptStackSelector;

/// The x86_64 Task State Segment structure.
pub const Tss = extern struct {
    reserved_1: u32 align(1) = 0,

    /// Stack pointers (RSP) for privilege levels 0-2.
    privilege_stack_table: [3]kernel.VirtualAddress align(1) = [_]kernel.VirtualAddress{kernel.VirtualAddress.zero} ** 3,

    reserved_2: u64 align(1) = 0,

    /// Interrupt stack table (IST) pointers.
    interrupt_stack_table: [7]kernel.VirtualAddress align(1) = [_]kernel.VirtualAddress{kernel.VirtualAddress.zero} ** 7,

    reserved_3: u64 align(1) = 0,

    reserved_4: u16 align(1) = 0,

    /// The 16-bit offset to the I/O permission bit map from the 64-bit TSS base.
    iomap_base: u16 align(1) = 0,

    /// Sets the stack for the given stack selector.
    pub fn setInterruptStack(self: *Tss, stack_selector: InterruptStackSelector, stack: []align(16) u8) void {
        self.interrupt_stack_table[@intFromEnum(stack_selector)] = kernel.VirtualAddress.fromInt(@intFromPtr(stack.ptr) + stack.len);
    }

    /// Sets the stack for the given privilege level.
    pub fn setPrivilegeStack(self: *Tss, privilege_level: x86_64.PrivilegeLevel, stack: []align(16) u8) void {
        core.assert(privilege_level != .ring3);
        self.privilege_stack_table[@intFromEnum(privilege_level)] = kernel.VirtualAddress.fromInt(@intFromPtr(stack.ptr) + stack.len);
    }

    pub const format = core.formatStructIgnoreReservedAndHiddenFields;

    comptime {
        core.testing.expectSize(@This(), 104);
    }
};

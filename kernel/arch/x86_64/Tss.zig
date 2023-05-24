// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const x86_64 = @import("x86_64.zig");

pub const Tss = extern struct {
    reserved_1: u32 align(1) = 0,

    /// Stack pointers (RSP) for privilege levels 0-2.
    privilege_stack_table: [3]kernel.arch.VirtAddr align(1) = [_]kernel.arch.VirtAddr{kernel.arch.VirtAddr.zero} ** 3,

    reserved_2: u64 align(1) = 0,

    /// Interrupt stack table (IST) pointers.
    interrupt_stack_table: [7]kernel.arch.VirtAddr align(1) = [_]kernel.arch.VirtAddr{kernel.arch.VirtAddr.zero} ** 7,

    reserved_3: u64 align(1) = 0,

    reserved_4: u16 align(1) = 0,

    /// The 16-bit offset to the I/O permission bit map from the 64-bit TSS base.
    iomap_base: u16 align(1) = 0,

    pub fn setInterruptStack(self: *Tss, stack_selector: u3, stack: []align(16) u8) void {
        self.interrupt_stack_table[stack_selector] = kernel.arch.VirtAddr.fromInt(@ptrToInt(stack.ptr) + stack.len);
    }

    pub fn setPrivilegeStack(self: *Tss, privilege_level: x86_64.PrivilegeLevel, stack: []align(16) u8) void {
        std.debug.assert(privilege_level != .ring3);
        self.privilege_stack_table[@enumToInt(privilege_level)] = kernel.arch.VirtAddr.fromInt(@ptrToInt(stack.ptr) + stack.len);
    }

    pub const format = kernel.utils.formatStructIgnoreReserved;

    comptime {
        std.debug.assert(@sizeOf(Tss) == 104);
        std.debug.assert(@bitSizeOf(Tss) == 104 * 8);
    }
};

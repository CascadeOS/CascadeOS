// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const apic = @import("apic.zig");
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

pub const spinLoopHint = lib_x64.instructions.pause;

pub const io = struct {
    pub const Port = u16;

    pub inline fn readPort(comptime T: type, port: Port) kernel.arch.io.PortError!T {
        return switch (T) {
            u8 => lib_x64.instructions.portReadU8(port),
            u16 => lib_x64.instructions.portReadU16(port),
            u32 => lib_x64.instructions.portReadU32(port),
            else => kernel.arch.io.PortError.UnsupportedPortSize,
        };
    }

    pub inline fn writePort(comptime T: type, port: Port, value: T) kernel.arch.io.PortError!void {
        return switch (T) {
            u8 => lib_x64.instructions.portWriteU8(port, value),
            u16 => lib_x64.instructions.portWriteU16(port, value),
            u32 => lib_x64.instructions.portWriteU32(port, value),
            else => kernel.arch.io.PortError.UnsupportedPortSize,
        };
    }
};

const std = @import("std");
const kernel = @import("kernel");
const lib_x64 = @import("x64");

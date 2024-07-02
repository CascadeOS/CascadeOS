// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const std = @import("std");

const riscv = @import("riscv");

pub inline fn pause() void {
    asm volatile ("pause");
}

/// Halt the CPU.
pub inline fn halt() void {
    asm volatile ("wfi");
}

/// Disable interrupts and put the CPU to sleep.
pub fn disableInterruptsAndHalt() noreturn {
    while (true) {
        riscv.SupervisorStatus.csr.clearBitsImmediate(0b10);
        asm volatile ("wfi");
    }
}

/// Disable interrupts.
pub inline fn disableInterrupts() void {
    riscv.SupervisorStatus.csr.clearBitsImmediate(0b10);
}

/// Enable interrupts.
pub inline fn enableInterrupts() void {
    riscv.SupervisorStatus.csr.setBitsImmediate(0b10);
}

/// Are interrupts enabled?
pub fn interruptsEnabled() bool {
    const sstatus = riscv.SupervisorStatus.read();
    return sstatus.sie;
}

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .Struct => |info| info.decls,
        .Enum => |info| info.decls,
        .Union => |info| info.decls,
        .Opaque => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

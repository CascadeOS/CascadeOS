// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub inline fn readTime() u64 {
    return asm ("rdtime %[ret]"
        : [ret] "=r" (-> u64),
    );
}

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
        riscv.registers.SupervisorStatus.csr.clearBitsImmediate(0b10);
        asm volatile ("wfi");
    }
}

/// Disable interrupts.
pub fn disableInterrupts() void {
    riscv.registers.SupervisorStatus.csr.clearBitsImmediate(0b10);
}
/// Enable interrupts.
pub fn enableInterrupts() void {
    riscv.registers.SupervisorStatus.csr.setBitsImmediate(0b10);
}
/// Are interrupts enabled?
pub fn interruptsEnabled() bool {
    const sstatus = riscv.registers.SupervisorStatus.read();
    return sstatus.sie;
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const riscv = @import("riscv");

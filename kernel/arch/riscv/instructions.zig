// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const riscv = @import("riscv.zig");

pub inline fn readTime() u64 {
    return asm ("rdtime %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn pause() void {
    asm volatile ("pause");
}

pub inline fn halt() void {
    asm volatile ("wfi");
}

/// Disable interrupts and put the CPU to sleep.
pub inline fn disableInterruptsAndHalt() noreturn {
    while (true) {
        riscv.registers.SupervisorStatus.csr.clearBitsImmediate(0b10);
        asm volatile ("wfi");
    }
}

pub inline fn disableInterrupts() void {
    riscv.registers.SupervisorStatus.csr.clearBitsImmediate(0b10);
}

pub inline fn enableInterrupts() void {
    riscv.registers.SupervisorStatus.csr.setBitsImmediate(0b10);
}

pub inline fn interruptsEnabled() bool {
    const sstatus = riscv.registers.SupervisorStatus.read();
    return sstatus.sie;
}

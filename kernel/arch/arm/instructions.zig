// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn readPhysicalCount() u64 {
    return asm ("mrs %[ret], cntpct_el0"
        : [ret] "=r" (-> u64),
    );
}

/// Halt the CPU.
pub fn halt() void {
    asm volatile ("wfe");
}

/// Instruction synchronization barrier.
///
/// Instruction Synchronization Barrier flushes the pipeline in the PE and is a context synchronization event.
pub fn isb() void {
    asm volatile ("isb" ::: .{ .memory = true });
}

/// Disable interrupts and put the CPU to sleep.
pub fn disableInterruptsAndHalt() noreturn {
    while (true) {
        asm volatile ("msr DAIFSet, #0b1111");
        asm volatile ("wfe");
    }
}

/// Disable interrupts.
pub fn disableInterrupts() void {
    asm volatile ("msr DAIFSet, #0b1111");
}

/// Enable interrupts.
pub fn enableInterrupts() void {
    asm volatile ("msr DAIFClr, #0b1111;");
}

/// Are interrupts enabled?
pub fn interruptsEnabled() bool {
    const daif = asm ("MRS %[daif], DAIF"
        : [daif] "=r" (-> u64),
    );
    const mask: u64 = 0b1111000000;
    return (daif & mask) == 0;
}

const core = @import("core");
const std = @import("std");

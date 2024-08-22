// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const Mutex = @import("Mutex.zig");
pub const TicketSpinLock = @import("TicketSpinLock.zig");
pub const WaitQueue = @import("WaitQueue.zig");

/// Acquire interrupt exclusion.
pub fn getInterruptExclusion() InterruptExclusion {
    kernel.arch.interrupts.disableInterrupts();

    const cpu = kernel.arch.rawGetCpu();

    cpu.interrupt_disable_count += 1;

    return .{ .cpu = cpu };
}

/// Acquire interrupt exclusion and that support restoring previous value of the disable count.
pub fn getInterruptExclusionRestorer() InterruptExclusionRestorer {
    kernel.arch.interrupts.disableInterrupts();

    const cpu = kernel.arch.rawGetCpu();

    const old_interrupt_disable_count = cpu.interrupt_disable_count;
    cpu.interrupt_disable_count = old_interrupt_disable_count + 1;

    return .{ .cpu = cpu, .old_interrupt_disable_count = old_interrupt_disable_count };
}

/// Asserts that interrupts are excluded with a disable count of 1.
pub fn assertInterruptExclusion() InterruptExclusion {
    std.debug.assert(!kernel.arch.interrupts.interruptsEnabled());

    const cpu = kernel.arch.rawGetCpu();

    std.debug.assert(cpu.interrupt_disable_count == 1);

    return .{ .cpu = cpu };
}

pub const InterruptExclusionRestorer = struct {
    cpu: *kernel.Cpu,
    old_interrupt_disable_count: u32,

    pub inline fn exclusion(self: InterruptExclusionRestorer) InterruptExclusion {
        return .{ .cpu = self.cpu };
    }

    pub inline fn restore(self: InterruptExclusionRestorer) void {
        // if this does not hold then just set it to the old value
        std.debug.assert(self.cpu.interrupt_disable_count == self.old_interrupt_disable_count);
        // self.cpu.interrupt_disable_count = self.old_interrupt_disable_count;
    }
};

pub const InterruptExclusion = struct {
    cpu: *kernel.Cpu,

    pub fn release(self: InterruptExclusion) void {
        std.debug.assert(!kernel.arch.interrupts.interruptsEnabled());

        const old_interrupt_disable_count = self.cpu.interrupt_disable_count;
        std.debug.assert(old_interrupt_disable_count != 0);

        self.cpu.interrupt_disable_count = old_interrupt_disable_count - 1;

        if (old_interrupt_disable_count == 1) kernel.arch.interrupts.enableInterrupts();
    }
};

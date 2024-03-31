// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const TicketSpinLock = @import("TicketSpinLock.zig");

pub const Exclusion = enum {
    preemption,
    preemption_and_interrupt,
};

const log = kernel.log.scoped(.sync);

pub const HeldExclusion = struct {
    cpu: *kernel.Cpu,
    exclusion: Exclusion,

    pub fn release(self: HeldExclusion) void {
        const old_preemption_disable_count = self.cpu.preemption_disable_count;
        core.debugAssert(old_preemption_disable_count != 0);

        self.cpu.preemption_disable_count = old_preemption_disable_count - 1;

        if (self.exclusion == .preemption_and_interrupt) {
            const old_interrupt_disable_count = self.cpu.interrupt_disable_count;
            core.debugAssert(old_interrupt_disable_count != 0);

            self.cpu.interrupt_disable_count = old_interrupt_disable_count - 1;

            if (old_interrupt_disable_count == 1) kernel.arch.interrupts.enableInterrupts();
        }

        // TODO: if (old_preemption_disable_count == 1) maybe reschedule?
    }
};

pub fn getCpuAndExclude(exclusion: Exclusion) HeldExclusion {
    kernel.arch.interrupts.disableInterrupts();

    const cpu = kernel.arch.rawGetCpu();

    cpu.preemption_disable_count += 1;

    if (exclusion == .preemption_and_interrupt) {
        cpu.interrupt_disable_count += 1;
    } else {
        if (cpu.interrupt_disable_count == 0) kernel.arch.interrupts.enableInterrupts();
    }

    return .{ .cpu = cpu, .exclusion = exclusion };
}

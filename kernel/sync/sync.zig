// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const TicketSpinLock = @import("TicketSpinLock.zig");

const log = kernel.log.scoped(.sync);

pub const PreemptionHalt = struct {
    cpu: *kernel.Cpu,

    pub fn release(self: PreemptionHalt) void {
        // interrupts could be enabled

        const old_preemption_disable_count = @atomicRmw(u32, &self.cpu.preemption_disable_count, .Sub, 1, .acq_rel);
        core.debugAssert(old_preemption_disable_count != 0);

        if (old_preemption_disable_count == 1 and @atomicLoad(u32, &self.cpu.schedules_skipped, .acquire) != 0) {
            const held = kernel.scheduler.lockScheduler();
            defer held.release();
            kernel.scheduler.queueThread(held, self.cpu.current_thread.?);
            kernel.scheduler.schedule(held);
        }
    }
};

pub const PreemptionInterruptHalt = struct {
    cpu: *kernel.Cpu,

    /// Enables interrupts leaving preemption disabled and returns a `PreemptionHalt`.
    ///
    /// __WARNING__
    ///
    /// The `PreemptionInterruptHalt` passed to this function must *not* have `release` called on it.
    pub fn downgrade(self: PreemptionInterruptHalt) PreemptionHalt {
        const old_interrupt_disable_count = self.cpu.interrupt_disable_count;
        core.debugAssert(old_interrupt_disable_count != 0);

        self.cpu.interrupt_disable_count -= 1;

        if (old_interrupt_disable_count == 1) kernel.arch.interrupts.enableInterrupts();

        return .{ .cpu = self.cpu };
    }

    pub inline fn release(self: PreemptionInterruptHalt) void {
        self.downgrade().release();
    }
};

pub fn getCpuPreemptionHalt() PreemptionHalt {
    kernel.arch.interrupts.disableInterrupts();

    const cpu = kernel.arch.rawGetCpu();

    cpu.preemption_disable_count += 1;

    if (cpu.interrupt_disable_count == 0) kernel.arch.interrupts.enableInterrupts();

    return .{ .cpu = cpu };
}

pub fn getCpuPreemptionInterruptHalt() PreemptionInterruptHalt {
    kernel.arch.interrupts.disableInterrupts();

    const cpu = kernel.arch.rawGetCpu();

    cpu.preemption_disable_count += 1;
    cpu.interrupt_disable_count += 1;

    return .{ .cpu = cpu };
}

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const TicketSpinLock = @This();

current: usize = 0,
ticket: usize = 0,
current_holder: kernel.Cpu.Id = .none,

pub const Held = struct {
    preemption_interrupt_halt: kernel.sync.PreemptionInterruptHalt,
    spinlock: *TicketSpinLock,

    /// Unlocks the spinlock.
    pub fn release(self: Held) void {
        core.debugAssert(self.spinlock.current_holder == self.preemption_interrupt_halt.cpu.id);

        self.spinlock.unsafeUnlock();
        self.preemption_interrupt_halt.release();
    }
};

pub fn isLocked(self: *const TicketSpinLock) bool {
    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) != .none;
}

/// Returns true if the spinlock is locked by the current cpu.
pub fn isLockedByCurrent(self: *const TicketSpinLock) bool {
    const preemption_halt = kernel.sync.getCpuPreemptionHalt();
    defer preemption_halt.release();

    return self.isLockedBy(preemption_halt.cpu.id);
}

pub fn isLockedBy(self: *const TicketSpinLock, cpu_id: kernel.Cpu.Id) bool {
    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) == cpu_id;
}

/// Unlocks the spinlock.
///
/// Intended to be used only when the caller needs to unlock the spinlock on behalf of another thread.
pub fn unsafeUnlock(self: *TicketSpinLock) void {
    @atomicStore(kernel.Cpu.Id, &self.current_holder, .none, .release);
    _ = @atomicRmw(usize, &self.current, .Add, 1, .acq_rel);
}

pub fn lock(self: *TicketSpinLock) Held {
    const preemption_interrupt_halt = kernel.sync.getCpuPreemptionInterruptHalt();

    const ticket = @atomicRmw(usize, &self.ticket, .Add, 1, .acq_rel);

    while (@atomicLoad(usize, &self.current, .acquire) != ticket) {
        kernel.arch.spinLoopHint();
    }
    @atomicStore(kernel.Cpu.Id, &self.current_holder, preemption_interrupt_halt.cpu.id, .release);

    return .{
        .preemption_interrupt_halt = preemption_interrupt_halt,
        .spinlock = self,
    };
}

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
    cpu_lock: kernel.sync.CpuLock,
    spinlock: *TicketSpinLock,

    /// Unlocks the spinlock.
    pub fn release(self: Held) void {
        core.debugAssert(self.spinlock.current_holder == self.cpu_lock.cpu.id);
        core.debugAssert(self.cpu_lock.exclusion == .preemption_and_interrupt);

        self.spinlock.unsafeUnlock();
        self.cpu_lock.release();
    }
};

pub fn isLocked(self: *const TicketSpinLock) bool {
    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) != .none;
}

/// Returns true if the spinlock is locked by the current cpu.
pub fn isLockedByCurrent(self: *const TicketSpinLock) bool {
    const cpu_lock = kernel.getLockedCpu(.preemption);
    defer cpu_lock.release();

    return self.isLockedBy(cpu_lock.cpu.id);
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
    const cpu_lock = kernel.getLockedCpu(.preemption_and_interrupt);

    const ticket = @atomicRmw(usize, &self.ticket, .Add, 1, .acq_rel);

    while (@atomicLoad(usize, &self.current, .acquire) != ticket) {
        kernel.arch.spinLoopHint();
    }
    @atomicStore(kernel.Cpu.Id, &self.current_holder, cpu_lock.cpu.id, .release);

    return .{
        .cpu_lock = cpu_lock,
        .spinlock = self,
    };
}

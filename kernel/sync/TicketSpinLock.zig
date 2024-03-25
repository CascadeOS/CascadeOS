// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const TicketSpinLock = @This();

/// The id of the cpu that currently holds the lock.
_cpu_id: kernel.Cpu.Id = .none,

pub const Held = struct {
    interrupts_enabled: bool,
    spinlock: *TicketSpinLock,

    /// Unlocks the spinlock.
    pub fn unlock(self: Held) void {
        core.debugAssert(kernel.arch.getCpu().id == self.spinlock._cpu_id);

        @atomicStore(kernel.Cpu.Id, &self.spinlock._cpu_id, .none, .release);
        if (self.interrupts_enabled) kernel.arch.interrupts.enableInterrupts();
    }
};

pub fn isLocked(self: TicketSpinLock) bool {
    return @atomicLoad(kernel.Cpu.Id, &self._cpu_id, .acquire) != .none;
}

pub fn isLockedByCurrent(self: TicketSpinLock) bool {
    return @atomicLoad(kernel.Cpu.Id, &self._cpu_id, .acquire) == kernel.arch.getCpu().id;
}

pub fn unsafeUnlock(self: *TicketSpinLock) void {
    @atomicStore(kernel.Cpu.Id, &self._cpu_id, .none, .release);
}

pub fn lock(self: *TicketSpinLock) Held {
    const interrupts_enabled = kernel.arch.interrupts.interruptsEnabled();
    if (interrupts_enabled) kernel.arch.interrupts.disableInterrupts();

    const id = kernel.arch.getCpu().id;

    while (true) {
        if (@cmpxchgWeak(
            kernel.Cpu.Id,
            &self._cpu_id,
            .none,
            id,
            .acq_rel,
            .acquire,
        )) |_| {
            kernel.arch.spinLoopHint();
            continue;
        }

        return .{
            .interrupts_enabled = interrupts_enabled,
            .spinlock = self,
        };
    }
}

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
    interrupts_enabled: bool,
    spinlock: *TicketSpinLock,

    /// Unlocks the spinlock.
    pub fn unlock(self: Held) void {
        core.debugAssert(self.spinlock.current_holder == kernel.arch.getCpu().id);

        self.spinlock.unsafeUnlock();
        if (self.interrupts_enabled) kernel.arch.interrupts.enableInterrupts();
    }
};

pub fn isLocked(self: TicketSpinLock) bool {
    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) != .none;
}

/// Returns true if the spinlock is locked by the current cpu.
///
/// It is the caller's responsibility to ensure that interrupts are disabled.
pub fn isLockedByCurrent(self: TicketSpinLock) bool {
    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) == kernel.arch.getCpu().id;
}

/// Unlocks the spinlock.
///
/// Intended to be used only when the caller needs to unlock the spinlock on behalf of another thread.
pub fn unsafeUnlock(self: *TicketSpinLock) void {
    @atomicStore(kernel.Cpu.Id, &self.current_holder, .none, .release);
    _ = @atomicRmw(usize, &self.current, .Add, 1, .acq_rel);
}

pub fn lock(self: *TicketSpinLock) Held {
    const interrupts_enabled = kernel.arch.interrupts.interruptsEnabled();
    if (interrupts_enabled) kernel.arch.interrupts.disableInterrupts();

    const ticket = @atomicRmw(usize, &self.ticket, .Add, 1, .acq_rel);

    while (@atomicLoad(usize, &self.current, .acquire) != ticket) {
        kernel.arch.spinLoopHint();
    }
    @atomicStore(kernel.Cpu.Id, &self.current_holder, kernel.arch.getCpu().id, .release);

    return .{
        .interrupts_enabled = interrupts_enabled,
        .spinlock = self,
    };
}

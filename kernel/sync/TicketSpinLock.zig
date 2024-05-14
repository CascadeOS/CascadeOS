// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const TicketSpinLock = @This();

current: u32 = 0,
ticket: u32 = 0,
current_holder: kernel.Cpu.Id = .none,

pub const Held = struct {
    exclusion: kernel.sync.Exclusion,
    spinlock: *TicketSpinLock,

    /// Unlocks the spinlock.
    pub fn release(self: Held) void {
        core.debugAssert(self.spinlock.isLockedBy(self.exclusion.cpu.id));

        self.spinlock.unsafeRelease();
        self.exclusion.release();
    }
};

pub fn isLockedBy(self: *const TicketSpinLock, cpu_id: kernel.Cpu.Id) bool {
    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) == cpu_id;
}

/// Releases the spinlock.
///
/// Intended to be used only when the caller needs to unlock the spinlock on behalf of another thread.
pub fn unsafeRelease(self: *TicketSpinLock) void {
    @atomicStore(kernel.Cpu.Id, &self.current_holder, .none, .release);
    _ = @atomicRmw(u32, &self.current, .Add, 1, .acq_rel);
}

pub fn acquire(self: *TicketSpinLock) Held {
    const exclusion = kernel.sync.getInterruptExclusion();

    core.debugAssert(!self.isLockedBy(exclusion.cpu.id));

    const ticket = @atomicRmw(u32, &self.ticket, .Add, 1, .acq_rel);

    while (@atomicLoad(u32, &self.current, .acquire) != ticket) {
        kernel.arch.spinLoopHint();
    }
    @atomicStore(kernel.Cpu.Id, &self.current_holder, exclusion.cpu.id, .release);

    return .{
        .exclusion = exclusion,
        .spinlock = self,
    };
}

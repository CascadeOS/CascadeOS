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
    exclusion: kernel.sync.InterruptExclusion,
    spinlock: *TicketSpinLock,

    /// Unlocks the spinlock.
    pub fn release(self: Held) void {
        std.debug.assert(self.spinlock.isLockedBy(self.exclusion.cpu.id));

        self.spinlock.unsafeRelease();
        self.exclusion.release();
    }
};

pub fn isLockedBy(self: *const TicketSpinLock, cpu_id: kernel.Cpu.Id) bool {
    return @atomicLoad(kernel.Cpu.Id, &self.current_holder, .acquire) == cpu_id;
}

/// Returns true if the spinlock is locked by the current cpu.
pub fn isLockedByCurrent(self: *const TicketSpinLock) bool {
    const cpu = kernel.arch.rawGetCpu();
    return self.isLockedBy(cpu.id);
}

/// Releases the spinlock.
///
/// Intended to be used only when the caller needs to unlock the spinlock on behalf of another task.
pub fn unsafeRelease(self: *TicketSpinLock) void {
    @atomicStore(kernel.Cpu.Id, &self.current_holder, .none, .release);
    _ = @atomicRmw(u32, &self.current, .Add, 1, .acq_rel);
}

pub fn acquire(self: *TicketSpinLock) Held {
    const exclusion = kernel.sync.getInterruptExclusion();

    std.debug.assert(!self.isLockedBy(exclusion.cpu.id));

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

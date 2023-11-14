// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const SpinLock = @This();

/// The ticket whose turn it is to acquire the lock.
current_ticket: usize = 1,

/// The ticket to hand out next.
next_available_ticket: usize = 1,

pub const Held = struct {
    interrupt_guard: kernel.arch.interrupts.InterruptGuard,
    spinlock: *SpinLock,

    /// Unlocks the spinlock.
    pub fn unlock(self: Held) void {
        _ = @atomicRmw(usize, &self.spinlock.current_ticket, .Add, 1, .Release);
        self.interrupt_guard.release();
    }
};

/// Grabs lock and disables interrupts atomically.
pub fn lock(self: *SpinLock) Held {
    const interrupt_guard = kernel.arch.interrupts.interruptGuard();

    const ticket = @atomicRmw(usize, &self.next_available_ticket, .Add, 1, .AcqRel);
    while (true) {
        const current_ticket = @atomicLoad(usize, &self.current_ticket, .Acquire);

        if (current_ticket == ticket) break; // we have the lock

        kernel.arch.spinLoopHint();
    }

    return .{
        .interrupt_guard = interrupt_guard,
        .spinlock = self,
    };
}

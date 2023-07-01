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
    enable_interrupts_on_unlock: bool,
    spinlock: *SpinLock,

    /// Unlocks the spinlock.
    pub fn unlock(self: Held) void {
        _ = @atomicRmw(usize, &self.spinlock.current_ticket, .Add, 1, .Release);

        if (self.enable_interrupts_on_unlock) kernel.arch.interrupts.enableInterrupts();
    }
};

/// Grabs lock and disables interrupts atomically.
pub fn lock(self: *SpinLock) Held {
    const interrupts_enabled = kernel.arch.interrupts.interruptsEnabled();

    kernel.arch.interrupts.disableInterrupts();

    self.internalGrab();

    return .{
        .enable_interrupts_on_unlock = interrupts_enabled,
        .spinlock = self,
    };
}

/// Grab lock without disabling interrupts
pub fn grab(self: *SpinLock) Held {
    self.internalGrab();
    return .{
        .enable_interrupts_on_unlock = false,
        .spinlock = self,
    };
}

fn internalGrab(self: *SpinLock) void {
    const ticket = @atomicRmw(usize, &self.next_available_ticket, .Add, 1, .AcqRel);
    while (true) {
        if (@atomicLoad(usize, &self.current_ticket, .Acquire) == ticket) {
            return;
        }
        kernel.arch.spinLoopHint();
    }
}

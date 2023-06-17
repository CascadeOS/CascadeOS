// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const SpinLock = @This();

z_serving: usize = 1,
z_allocated: usize = 1,

pub const Held = struct {
    z_enable_interrupts_on_unlock: bool,
    z_spinlock: *SpinLock,

    pub fn unlock(self: Held) void {
        _ = @atomicRmw(usize, &self.z_spinlock.z_serving, .Add, 1, .Release);
        if (self.z_enable_interrupts_on_unlock) kernel.arch.interrupts.enableInterrupts();
    }
};

/// Grabs lock and disables interrupts atomically.
pub fn lock(self: *SpinLock) Held {
    const interrupts_enabled = kernel.arch.interrupts.interruptsEnabled();

    kernel.arch.interrupts.disableInterrupts();

    self.internalGrab(interrupts_enabled);

    return .{
        .z_enable_interrupts_on_unlock = interrupts_enabled,
        .z_spinlock = self,
    };
}

/// Grab lock without disabling interrupts
pub fn grab(self: *SpinLock) Held {
    self.internalGrab(false);
    return .{
        .z_enable_interrupts_on_unlock = false,
        .z_spinlock = self,
    };
}

fn internalGrab(self: *SpinLock, interrupts_were_enabled: bool) void {
    const ticket = @atomicRmw(usize, &self.z_allocated, .Add, 1, .AcqRel);
    while (true) {
        if (@atomicLoad(usize, &self.z_serving, .Acquire) == ticket) {
            return;
        }
        if (interrupts_were_enabled) {
            kernel.arch.interrupts.enableInterrupts();
            kernel.arch.interrupts.disableInterrupts();
        }
        kernel.arch.spinLoopHint();
    }
}

// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const SpinLock = @This();

/// The id of the processor that currently holds the lock + 1.
///
/// If the lock is currently unlocked, this is 0.
_processor_plus_one: usize = 0,

pub const Held = struct {
    interrupts_enabled: bool,
    spinlock: *SpinLock,

    /// Unlocks the spinlock.
    pub fn unlock(self: Held) void {
        core.debugAssert(kernel.arch.getProcessor().id + 1 == self.spinlock._processor_plus_one);

        @atomicStore(usize, &self.spinlock._processor_plus_one, 0, .Release);
        if (self.interrupts_enabled) kernel.arch.interrupts.enableInterrupts();
    }
};

pub fn unsafeUnlock(self: *SpinLock) void {
    @atomicStore(usize, &self._processor_plus_one, 0, .Release);
}

pub fn lock(self: *SpinLock) Held {
    const interrupts_enabled = kernel.arch.interrupts.interruptsEnabled();
    if (interrupts_enabled) kernel.arch.interrupts.disableInterrupts();

    const processor = kernel.arch.getProcessor();

    const processor_id_plus_one = processor.id + 1;

    while (true) {
        if (@cmpxchgWeak(
            usize,
            &self._processor_plus_one,
            0,
            processor_id_plus_one,
            .AcqRel,
            .Acquire,
        )) |current| {
            core.debugAssert(current != processor_id_plus_one);

            kernel.arch.spinLoopHint();

            continue;
        }

        return .{
            .interrupts_enabled = interrupts_enabled,
            .spinlock = self,
        };
    }
}

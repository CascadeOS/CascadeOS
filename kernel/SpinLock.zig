// SPDX-License-Identifier: MIT

const arch = kernel.arch;
const core = @import("core");
const kernel = @import("kernel");
const Processor = kernel.Processor;
const std = @import("std");

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
        core.debugAssert(@intFromEnum(Processor.get().id) + 1 == self.spinlock._processor_plus_one);

        @atomicStore(usize, &self.spinlock._processor_plus_one, 0, .Release);
        if (self.interrupts_enabled) arch.interrupts.enableInterrupts();
    }
};

pub fn isLocked(self: SpinLock) bool {
    return @atomicLoad(usize, &self._processor_plus_one, .Acquire) != 0;
}

pub fn isLockedByCurrent(self: SpinLock) bool {
    return @atomicLoad(usize, &self._processor_plus_one, .Acquire) == @intFromEnum(Processor.get().id) + 1;
}

pub fn unsafeUnlock(self: *SpinLock) void {
    @atomicStore(usize, &self._processor_plus_one, 0, .Release);
}

pub fn lock(self: *SpinLock) Held {
    const interrupts_enabled = arch.interrupts.interruptsEnabled();
    if (interrupts_enabled) arch.interrupts.disableInterrupts();

    const processor = Processor.get();

    const processor_id_plus_one = @intFromEnum(processor.id) + 1;

    while (true) {
        if (@cmpxchgWeak(
            usize,
            &self._processor_plus_one,
            0,
            processor_id_plus_one,
            .AcqRel,
            .Acquire,
        )) |_| {
            arch.spinLoopHint();
            continue;
        }

        return .{
            .interrupts_enabled = interrupts_enabled,
            .spinlock = self,
        };
    }
}

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const SpinLock = @This();

/// The id of the processor that currently holds the lock.
_processor_id: kernel.Processor.Id = .none,

pub const Held = struct {
    interrupts_enabled: bool,
    spinlock: *SpinLock,

    /// Unlocks the spinlock.
    pub fn unlock(self: Held) void {
        core.debugAssert(kernel.arch.getProcessor().id == self.spinlock._processor_id);

        @atomicStore(kernel.Processor.Id, &self.spinlock._processor_id, .none, .Release);
        if (self.interrupts_enabled) kernel.arch.interrupts.enableInterrupts();
    }
};

pub fn isLocked(self: SpinLock) bool {
    return @atomicLoad(kernel.Processor.Id, &self._processor_id, .Acquire) != .none;
}

pub fn isLockedByCurrent(self: SpinLock) bool {
    return @atomicLoad(kernel.Processor.Id, &self._processor_id, .Acquire) == kernel.arch.getProcessor().id;
}

pub fn unsafeUnlock(self: *SpinLock) void {
    @atomicStore(kernel.Processor.Id, &self._processor_id, .none, .Release);
}

pub fn lock(self: *SpinLock) Held {
    const interrupts_enabled = kernel.arch.interrupts.interruptsEnabled();
    if (interrupts_enabled) kernel.arch.interrupts.disableInterrupts();

    const processor = kernel.arch.getProcessor();

    const processor_id = processor.id;

    while (true) {
        if (@cmpxchgWeak(
            kernel.Processor.Id,
            &self._processor_id,
            .none,
            processor_id,
            .AcqRel,
            .Acquire,
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

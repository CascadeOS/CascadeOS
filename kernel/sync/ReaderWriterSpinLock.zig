// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const ReaderWriterSpinLock = @This();

lock: kernel.sync.TicketSpinLock = .{},
number_of_readers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

pub fn readLock(self: *ReaderWriterSpinLock) void {
    const held = self.lock.lock();
    defer held.unlock();

    _ = self.number_of_readers.fetchAdd(1, .acq_rel);
}

pub fn readUnlock(self: *ReaderWriterSpinLock) void {
    _ = self.number_of_readers.fetchSub(1, .acq_rel);
}

pub fn writeLock(self: *ReaderWriterSpinLock) kernel.sync.TicketSpinLock.Held {
    const held = self.lock.lock();

    while (self.number_of_readers.load(.acquire) != 0) {
        std.atomic.spinLoopHint();
    }

    return held;
}

pub fn writeUnlock(self: *ReaderWriterSpinLock, held: kernel.sync.TicketSpinLock.Held) void {
    _ = self;
    held.unlock();
}

pub fn upgradeReadToWriteLock(self: *ReaderWriterSpinLock) kernel.sync.TicketSpinLock.Held {
    self.readUnlock();
    return self.writeLock();
}

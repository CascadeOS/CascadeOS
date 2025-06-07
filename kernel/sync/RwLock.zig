// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A reader writer lock.
//!
//! Based on `std.Thread.RwLock.DefaultRwLock`.
//!
//! TODO: replace this with something better, there should be no need for a mutex and we want seperate queues for
//! readers and writers allowing us to wake all readers when a write lock is released

const RwLock = @This();

state: usize = 0,
mutex: kernel.sync.Mutex = .{},

wait_queue_spinlock: kernel.sync.TicketSpinLock = .{},
wait_queue: kernel.sync.WaitQueue = .{},

pub fn tryWriteLock(rw_lock: *RwLock, current_task: *kernel.Task) bool {
    if (rw_lock.mutex.tryLock(current_task)) {
        const state = @atomicLoad(usize, &rw_lock.state, .monotonic);

        if (state & READER_MASK == 0) {
            _ = @atomicRmw(usize, &rw_lock.state, .Or, IS_WRITING, .acquire);
            return true;
        }

        rw_lock.mutex.unlock(current_task);
    }

    return false;
}

pub fn writeLock(rw_lock: *RwLock, current_task: *kernel.Task) void {
    _ = @atomicRmw(usize, &rw_lock.state, .Add, WRITER, .acquire);
    rw_lock.mutex.lock(current_task);

    const state = @atomicRmw(
        usize,
        &rw_lock.state,
        .Add,
        IS_WRITING -% WRITER,
        .acquire,
    );

    if (state & READER_MASK != 0) {
        rw_lock.wait_queue_spinlock.lock(current_task);
        rw_lock.wait_queue.wait(current_task, &rw_lock.wait_queue_spinlock);
    }
}

pub fn writeUnlock(rw_lock: *RwLock, current_task: *kernel.Task) void {
    _ = @atomicRmw(usize, &rw_lock.state, .And, ~IS_WRITING, .release);
    rw_lock.mutex.unlock(current_task);
}

pub fn tryReadLock(rw_lock: *RwLock, current_task: *kernel.Task) bool {
    const state = @atomicLoad(usize, &rw_lock.state, .monotonic);

    if (state & (IS_WRITING | WRITER_MASK) == 0) {
        _ = @cmpxchgStrong(
            usize,
            &rw_lock.state,
            state,
            state + READER,
            .acquire,
            .monotonic,
        ) orelse return true;
    }

    if (rw_lock.mutex.tryLock(current_task)) {
        _ = @atomicRmw(usize, &rw_lock.state, .Add, READER, .acquire);
        rw_lock.mutex.unlock(current_task);
        return true;
    }

    return false;
}

pub fn readLock(rw_lock: *RwLock, current_task: *kernel.Task) void {
    var state = @atomicLoad(usize, &rw_lock.state, .monotonic);

    while (state & (IS_WRITING | WRITER_MASK) == 0) {
        state = @cmpxchgWeak(
            usize,
            &rw_lock.state,
            state,
            state + READER,
            .acquire,
            .monotonic,
        ) orelse return;
    }

    rw_lock.mutex.lock(current_task);
    _ = @atomicRmw(usize, &rw_lock.state, .Add, READER, .acquire);
    rw_lock.mutex.unlock(current_task);
}

pub fn readUnlock(rw_lock: *RwLock, current_task: *kernel.Task) void {
    const state = @atomicRmw(usize, &rw_lock.state, .Sub, READER, .release);

    if ((state & READER_MASK == READER) and (state & IS_WRITING != 0)) {
        rw_lock.wait_queue_spinlock.lock(current_task);
        rw_lock.wait_queue.wakeOne(current_task, &rw_lock.wait_queue_spinlock);
    }
}

const IS_WRITING: usize = 1;
const WRITER: usize = 1 << 1;
const READER: usize = 1 << (1 + @bitSizeOf(Count));
const WRITER_MASK: usize = std.math.maxInt(Count) << @ctz(WRITER);
const READER_MASK: usize = std.math.maxInt(Count) << @ctz(READER);
const Count = std.meta.Int(.unsigned, @divFloor(@bitSizeOf(usize) - 1, 2));

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

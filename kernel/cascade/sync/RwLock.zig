// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A reader writer lock.
//!
//! Based on `std.Thread.RwLock.DefaultRwLock`.
//!
//! TODO: replace this with something better, there should be no need for a mutex and we want seperate queues for
//! readers and writers allowing us to wake all readers when a write lock is released

const std = @import("std");

const cascade = @import("cascade");
const core = @import("core");

const RwLock = @This();

state: usize = 0,
mutex: cascade.sync.Mutex = .{},

wait_queue_spinlock: cascade.sync.TicketSpinLock = .{},
wait_queue: cascade.sync.WaitQueue = .{},

/// Attempt to upgrade a read lock to a write lock.
///
/// Returns `true` if the upgrade was successful.
///
/// If it fails the lock is left unlocked.
pub fn tryUpgradeLock(rw_lock: *RwLock, context: *cascade.Task.Context) bool {
    _ = @atomicRmw(usize, &rw_lock.state, .Add, WRITER, .acquire);

    if (rw_lock.mutex.tryLock(context)) {
        const state = @atomicRmw(usize, &rw_lock.state, .Sub, READER, .release);

        if (state & READER_MASK == READER) {
            _ = @atomicRmw(usize, &rw_lock.state, .Or, IS_WRITING, .acquire);
            return true;
        }

        _ = @atomicRmw(usize, &rw_lock.state, .Sub, WRITER, .release);

        rw_lock.mutex.unlock(context);
    } else {
        _ = @atomicRmw(usize, &rw_lock.state, .Sub, READER + WRITER, .release);
    }

    return false;
}

pub fn tryWriteLock(rw_lock: *RwLock, context: *cascade.Task.Context) bool {
    if (rw_lock.mutex.tryLock(context)) {
        const state = @atomicLoad(usize, &rw_lock.state, .monotonic);

        if (state & READER_MASK == 0) {
            _ = @atomicRmw(usize, &rw_lock.state, .Or, IS_WRITING, .acquire);
            return true;
        }

        rw_lock.mutex.unlock(context);
    }

    return false;
}

pub fn writeLock(rw_lock: *RwLock, context: *cascade.Task.Context) void {
    _ = @atomicRmw(usize, &rw_lock.state, .Add, WRITER, .acquire);
    rw_lock.mutex.lock(context);

    const state = @atomicRmw(
        usize,
        &rw_lock.state,
        .Add,
        IS_WRITING -% WRITER,
        .acquire,
    );

    if (state & READER_MASK != 0) {
        rw_lock.wait_queue_spinlock.lock(context);
        rw_lock.wait_queue.wait(context, &rw_lock.wait_queue_spinlock);
    }
}

pub fn writeUnlock(rw_lock: *RwLock, context: *cascade.Task.Context) void {
    _ = @atomicRmw(usize, &rw_lock.state, .And, ~IS_WRITING, .release);
    rw_lock.mutex.unlock(context);
}

/// Returns `true` if the lock is read locked.
///
/// This value can only be trusted if the lock is held by the current task.
pub fn isReadLocked(rw_lock: *const RwLock) bool {
    const state = @atomicLoad(usize, &rw_lock.state, .monotonic);
    return state & READER_MASK != 0;
}

/// Returns `true` if the lock is read locked.
///
/// This value can only be trusted if the lock is held by the current task.
pub fn isWriteLocked(rw_lock: *const RwLock) bool {
    const state = @atomicLoad(usize, &rw_lock.state, .monotonic);
    return state & IS_WRITING != 0;
}

pub fn tryReadLock(rw_lock: *RwLock, context: *cascade.Task.Context) bool {
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

    if (rw_lock.mutex.tryLock(context)) {
        _ = @atomicRmw(usize, &rw_lock.state, .Add, READER, .acquire);
        rw_lock.mutex.unlock(context);
        return true;
    }

    return false;
}

pub fn readLock(rw_lock: *RwLock, context: *cascade.Task.Context) void {
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

    rw_lock.mutex.lock(context);
    _ = @atomicRmw(usize, &rw_lock.state, .Add, READER, .acquire);
    rw_lock.mutex.unlock(context);
}

pub fn readUnlock(rw_lock: *RwLock, context: *cascade.Task.Context) void {
    const state = @atomicRmw(usize, &rw_lock.state, .Sub, READER, .release);

    if ((state & READER_MASK == READER) and (state & IS_WRITING != 0)) {
        rw_lock.wait_queue_spinlock.lock(context);
        defer rw_lock.wait_queue_spinlock.unlock(context);

        rw_lock.wait_queue.wakeOne(context, &rw_lock.wait_queue_spinlock);
    }
}

const IS_WRITING: usize = 1;
const WRITER: usize = 1 << 1;
const READER: usize = 1 << (1 + @bitSizeOf(Count));
const WRITER_MASK: usize = std.math.maxInt(Count) << @ctz(WRITER);
const READER_MASK: usize = std.math.maxInt(Count) << @ctz(READER);
const Count = std.meta.Int(.unsigned, @divFloor(@bitSizeOf(usize) - 1, 2));

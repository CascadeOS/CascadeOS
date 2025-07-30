// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A synchronization primitive that allows a single task to block (park) and any other task to wake it (unpark).

// TODO: the atomic orderings in this file are probably wrong, but the same can be said for all orderings in the repo...

const Parker = @This();

lock: kernel.sync.TicketSpinLock = .{},
parked_task: ?*kernel.Task,

unpark_attempts: std.atomic.Value(usize) = .init(0),

pub const empty: Parker = .{ .parked_task = null };

/// Initialize the parker with a already parked task.
///
/// The task will be set to the `blocked` state.
///
/// It is the caller's responsibility to ensure that the task is not currently running, queued for scheduling,
/// or blocked.
pub fn withParkedTask(parked_task: *kernel.Task) Parker {
    std.debug.assert(parked_task.state == .ready);
    parked_task.state = .blocked;
    return .{ .parked_task = parked_task };
}

/// Park (block) the current task.
pub fn park(parker: *Parker, current_task: *kernel.Task) void {
    std.debug.assert(current_task.state == .running);

    if (parker.unpark_attempts.load(.acquire) != 0) {
        parker.unpark_attempts.store(0, .release);
        return;
    }

    parker.lock.lock(current_task);
    std.debug.assert(parker.parked_task == null);

    if (parker.unpark_attempts.swap(0, .acq_rel) != 0) {
        parker.lock.unlock(current_task);
        return;
    }

    parker.parked_task = current_task;

    kernel.scheduler.lockScheduler(current_task);
    defer kernel.scheduler.unlockScheduler(current_task);

    kernel.scheduler.drop(current_task, .{
        .action = struct {
            fn action(_: *kernel.Task, old_task: *kernel.Task, context: ?*anyopaque) void {
                const inner_parker: *Parker = @ptrCast(@alignCast(context));

                old_task.state = .blocked;
                old_task.spinlocks_held -= 1;
                old_task.interrupt_disable_count -= 1;

                inner_parker.parked_task = old_task;
                inner_parker.lock.unsafeUnlock();
            }
        }.action,
        .context = parker,
    });
}

/// Unpark (wake) the parked task if it is currently parked.
pub fn unpark(
    parker: *Parker,
    current_task: *kernel.Task,
    scheduler_locked: core.LockState,
) void {
    if (parker.unpark_attempts.fetchAdd(1, .acq_rel) != 0) {
        // someone else was the first to attempt to unpark the task, so we can leave waking the task to them
        return;
    }

    const parked_task = blk: {
        parker.lock.lock(current_task);
        defer parker.lock.unlock(current_task);

        const parked_task = parker.parked_task orelse return;
        parker.parked_task = null;
        break :blk parked_task;
    };
    std.debug.assert(parked_task.state == .blocked);

    parked_task.state = .ready;

    switch (scheduler_locked) {
        .unlocked => kernel.scheduler.lockScheduler(current_task),
        .locked => std.debug.assert(kernel.scheduler.isLockedByCurrent(current_task)),
    }
    defer switch (scheduler_locked) {
        .unlocked => kernel.scheduler.unlockScheduler(current_task),
        .locked => {},
    };

    kernel.scheduler.queueTask(current_task, parked_task);
    parker.unpark_attempts.store(0, .release);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

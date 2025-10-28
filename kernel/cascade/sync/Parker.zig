// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A synchronization primitive that allows a single task to block (park) and any other task to wake it (unpark).

const std = @import("std");

const cascade = @import("cascade");
const core = @import("core");

const Parker = @This();

lock: cascade.sync.TicketSpinLock = .{},
parked_task: ?*cascade.Task,
unpark_attempts: std.atomic.Value(usize) = .init(0),

pub const empty: Parker = .{ .parked_task = null };

/// Initialize the parker with a already parked task.
///
/// The task will be set to the `blocked` state.
///
/// It is the caller's responsibility to ensure that the task is not currently running, queued for scheduling,
/// or blocked.
pub fn withParkedTask(parked_task: *cascade.Task) Parker {
    if (core.is_debug) std.debug.assert(parked_task.state == .ready);
    parked_task.state = .blocked;
    return .{ .parked_task = parked_task };
}

/// Park (block) the current task.
///
/// Spurious wakeups are possible.
pub fn park(parker: *Parker, context: *cascade.Task.Context) void {
    if (core.is_debug) std.debug.assert(context.task().state == .running);

    if (parker.unpark_attempts.swap(0, .acq_rel) != 0) {
        return; // there were some wakeups, they might be spurious
    }

    cascade.scheduler.lockScheduler(context);
    defer cascade.scheduler.unlockScheduler(context);

    // recheck for unpark attempts that happened while we were locking the scheduler
    if (parker.unpark_attempts.swap(0, .acq_rel) != 0) {
        @branchHint(.unlikely);
        return;
    }

    parker.lock.lock(context);
    if (core.is_debug) std.debug.assert(parker.parked_task == null);

    // recheck for unpark attempts that happened while we were locking the parker lock
    if (parker.unpark_attempts.swap(0, .acq_rel) != 0) {
        @branchHint(.unlikely);
        parker.lock.unlock(context);
        return;
    }

    cascade.scheduler.drop(context, .{
        .action = struct {
            fn action(_: *cascade.Task.Context, old_task: *cascade.Task, arg: usize) void {
                const inner_parker: *Parker = @ptrFromInt(arg);

                old_task.state = .blocked;
                old_task.context.spinlocks_held -= 1;
                old_task.context.interrupt_disable_count -= 1;

                inner_parker.parked_task = old_task;
                inner_parker.lock.unsafeUnlock();
            }
        }.action,
        .arg = @intFromPtr(parker),
    });

    parker.unpark_attempts.store(0, .release);
}

/// Unpark (wake) the parked task if it is currently parked.
pub fn unpark(
    parker: *Parker,
    context: *cascade.Task.Context,
) void {
    if (parker.unpark_attempts.fetchAdd(1, .acq_rel) != 0) {
        // someone else was the first to attempt to unpark the task, so we can leave waking the task to them
        return;
    }

    const parked_task = blk: {
        parker.lock.lock(context);
        defer parker.lock.unlock(context);

        const parked_task = parker.parked_task orelse return;
        parker.parked_task = null;
        break :blk parked_task;
    };
    if (core.is_debug) std.debug.assert(parked_task.state == .blocked);

    parked_task.state = .ready;

    const scheduler_already_locked = context.scheduler_locked;

    switch (scheduler_already_locked) {
        true => if (core.is_debug) cascade.scheduler.assertSchedulerLocked(context),
        false => cascade.scheduler.lockScheduler(context),
    }
    defer switch (scheduler_already_locked) {
        true => {},
        false => cascade.scheduler.unlockScheduler(context),
    };

    cascade.scheduler.queueTask(context, parked_task);
}

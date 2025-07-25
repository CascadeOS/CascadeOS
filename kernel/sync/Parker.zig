// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A synchronization primitive that allows a single task to block (park) and any other task to wake it (unpark).

// TODO: the atomic orderings in this file are probably wrong, but the same can be said for all orderings in the repo...

const Parker = @This();

parked_task: std.atomic.Value(?*kernel.Task),

// used to make sure that we don't lose any wakeups
unpark_attempts: std.atomic.Value(usize) = .init(0),

pub const empty: Parker = .{ .parked_task = .init(null) };

/// Initialize the parker with a already parked task.
///
/// The task will be set to the `blocked` state.
///
/// It is the caller's responsibility to ensure that the task is not currently running, queued for scheduling,
/// or blocked.
pub fn withParkedTask(parked_task: *kernel.Task) Parker {
    std.debug.assert(parked_task.state == .ready);
    parked_task.state = .blocked;
    return .{ .parked_task = .init(parked_task) };
}

/// Park (block) the current task.
///
/// Spurious wakeups are possible.
pub fn park(parker: *Parker, current_task: *kernel.Task, scheduler_locked: core.LockState) void {
    std.debug.assert(current_task.state == .running);

    if (parker.unpark_attempts.swap(0, .acq_rel) != 0) {
        return; // there were some wakeups, they might be spurious
    }

    switch (scheduler_locked) {
        .unlocked => {
            kernel.scheduler.lockScheduler(current_task);

            // recheck for unpark attempts that happened while we were locking the scheduler
            if (parker.unpark_attempts.swap(0, .acq_rel) != 0) {
                kernel.scheduler.unlockScheduler(current_task);
                return;
            }
        },
        .locked => {},
    }

    kernel.scheduler.drop(current_task, .{
        .action = struct {
            fn action(new_current_task: *kernel.Task, old_task: *kernel.Task, context: ?*anyopaque) void {
                const inner_parker: *Parker = @ptrCast(@alignCast(context));

                if (inner_parker.unpark_attempts.swap(0, .acq_rel) != 0) {
                    // someone has attempted to unpark the task, so reschedule it
                    old_task.state = .ready;
                    kernel.scheduler.queueTask(new_current_task, old_task);
                    return;
                }

                // TODO: there is still a window right here where a task can attempt to unpark us but we park ourselves
                // anyway, we would need to use a lock to prevent this...

                old_task.state = .blocked;

                std.debug.assert(
                    inner_parker.parked_task.swap(
                        old_task,
                        .acq_rel,
                    ) == null,
                );
            }
        }.action,
        .context = parker,
    });

    switch (scheduler_locked) {
        .unlocked => kernel.scheduler.unlockScheduler(current_task),
        .locked => {},
    }
}

/// Unpark (wake) the parked task if it is currently parked.
pub fn unpark(
    parker: *Parker,
    current_task: *kernel.Task,
    scheduler_locked: core.LockState,
) void {
    _ = parker.unpark_attempts.fetchAdd(1, .acq_rel);

    const parked_task = parker.parked_task.swap(null, .acq_rel) orelse return;
    std.debug.assert(parked_task.state == .blocked);

    parked_task.state = .ready;

    switch (scheduler_locked) {
        .unlocked => kernel.scheduler.lockScheduler(current_task),
        .locked => {},
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

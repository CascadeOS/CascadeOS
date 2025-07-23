// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A synchronization primitive that allows a single task to block (park) and any other task to wake it (unpark).

const Parker = @This();

parked_task: std.atomic.Value(?*kernel.Task),

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
pub fn park(parker: *Parker, current_task: *kernel.Task, scheduler_locked: core.LockState) void {
    std.debug.assert(current_task.state == .running);

    switch (scheduler_locked) {
        .unlocked => kernel.scheduler.lockScheduler(current_task),
        .locked => {},
    }
    defer switch (scheduler_locked) {
        .unlocked => kernel.scheduler.unlockScheduler(current_task),
        .locked => {},
    };

    kernel.scheduler.drop(current_task, .{
        .action = struct {
            fn action(old_task: *kernel.Task, context: ?*anyopaque) void {
                const inner_parker: *Parker = @ptrCast(@alignCast(context));
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
}

/// Unpark (wake) the parked task if it is currently parked.
pub fn unpark(
    parker: *Parker,
    current_task: *kernel.Task,
    scheduler_locked: core.LockState,
) void {
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
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

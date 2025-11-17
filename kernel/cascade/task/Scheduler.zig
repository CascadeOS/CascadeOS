// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Process = cascade.Process;
const core = @import("core");

const log = cascade.debug.log.scoped(.scheduler);

/// Queues a task to be run by the scheduler.
///
/// Must be called with the scheduler lock held.
pub fn queueTask(current_task: Task.Current, task: *Task) void {
    if (core.is_debug) {
        std.debug.assert(!task.is_scheduler_task); // cannot queue a scheduler task
        assertSchedulerLocked(current_task);
        std.debug.assert(task.state == .ready);
    }

    globals.ready_to_run.append(&task.next_task_node);
}

pub inline fn isEmpty() bool {
    return globals.ready_to_run.isEmpty();
}

/// Returns the next task to run.
///
/// Must be called with the scheduler lock held.
pub fn getNextTask(current_task: Task.Current) ?*Task {
    if (core.is_debug) assertSchedulerLocked(current_task);

    const task_node = globals.ready_to_run.pop() orelse return null; // no tasks to run
    const task: *Task = .fromNode(task_node);

    if (core.is_debug) {
        std.debug.assert(!task.is_scheduler_task);
        std.debug.assert(task.state == .ready);
    }

    return task;
}

pub fn lockScheduler(current_task: Task.Current) void {
    globals.lock.lock(current_task);
    current_task.task.scheduler_locked = true;
}

pub fn unlockScheduler(current_task: Task.Current) void {
    current_task.task.scheduler_locked = false;
    globals.lock.unlock(current_task);
}

/// Asserts that the scheduler lock is held by the current task.
pub inline fn assertSchedulerLocked(current_task: Task.Current) void {
    std.debug.assert(current_task.task.scheduler_locked);
    std.debug.assert(globals.lock.isLockedByCurrent(current_task));
}

/// Asserts that the scheduler lock is not held by the current task.
pub inline fn assertSchedulerNotLocked(current_task: Task.Current) void {
    std.debug.assert(!current_task.task.scheduler_locked);
    std.debug.assert(!globals.lock.isLockedByCurrent(current_task));
}

const globals = struct {
    var lock: cascade.sync.TicketSpinLock = .{};
    var ready_to_run: core.containers.FIFO = .{};
};

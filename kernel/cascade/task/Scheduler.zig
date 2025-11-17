// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Process = cascade.Process;
const core = @import("core");

const log = cascade.debug.log.scoped(.scheduler);

const Scheduler = @This();

ticket_spin_lock: cascade.sync.TicketSpinLock = .{},
ready_to_run: core.containers.FIFO = .{},

pub fn queueTask(scheduler: *Scheduler, task: *Task) void {
    scheduler.ready_to_run.append(&task.next_task_node);
}

pub fn isEmpty(scheduler: *const Scheduler) bool {
    return scheduler.ready_to_run.isEmpty();
}

pub fn getNextTask(scheduler: *Scheduler) ?*Task {
    const task_node = scheduler.ready_to_run.pop() orelse return null; // no tasks to run
    const task: *Task = .fromNode(task_node);

    if (core.is_debug) {
        std.debug.assert(!task.is_scheduler_task);
        std.debug.assert(task.state == .ready);
    }

    return task;
}

pub fn lock(scheduler: *Scheduler, current_task: Task.Current) void {
    scheduler.ticket_spin_lock.lock(current_task);
    current_task.task.scheduler_locked = true;
}

pub fn unlock(scheduler: *Scheduler, current_task: Task.Current) void {
    current_task.task.scheduler_locked = false;
    scheduler.ticket_spin_lock.unlock(current_task);
}

/// Asserts that the scheduler lock is held by the current task.
pub inline fn assertLocked(scheduler: *const Scheduler, current_task: Task.Current) void {
    std.debug.assert(current_task.task.scheduler_locked);
    std.debug.assert(scheduler.ticket_spin_lock.isLockedByCurrent(current_task));
}

/// Asserts that the scheduler lock is not held by the current task.
pub inline fn assertNotLocked(scheduler: *const Scheduler, current_task: Task.Current) void {
    std.debug.assert(!current_task.task.scheduler_locked);
    std.debug.assert(!scheduler.ticket_spin_lock.isLockedByCurrent(current_task));
}

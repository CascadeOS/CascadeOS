// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const WaitQueue = @This();

waiting_tasks: containers.SinglyLinkedFIFO = .empty,

/// Returns the first task in the wait queue.
///
/// It is the callers responsibility to ensure that the task is not removed from the wait queue.
pub fn firstTask(wait_queue: *WaitQueue) ?*kernel.Task {
    const node = wait_queue.waiting_tasks.start_node orelse return null;
    return kernel.Task.fromNode(node);
}

/// Wake one task from the wait queue.
///
/// Asserts that the spinlock is locked by the current executor and interrupts are disabled.
pub fn wakeOne(
    wait_queue: *WaitQueue,
    current_task: *kernel.Task,
    spinlock: *const kernel.sync.TicketSpinLock,
) void {
    std.debug.assert(current_task.interrupt_disable_count != 0);
    std.debug.assert(spinlock.isLockedByCurrent(current_task));

    const task_to_wake_node = wait_queue.waiting_tasks.pop() orelse return;
    const task_to_wake = kernel.Task.fromNode(task_to_wake_node);

    std.debug.assert(task_to_wake.state == .blocked);
    task_to_wake.state = .ready;

    kernel.scheduler.lockScheduler(current_task);
    defer kernel.scheduler.unlockScheduler(current_task);

    kernel.scheduler.queueTask(current_task, task_to_wake);
}

/// Add the current task to the wait queue.
///
/// Asserts that the spinlock is locked by the current executor and interrupts are disabled.
pub fn wait(
    wait_queue: *WaitQueue,
    current_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
) void {
    std.debug.assert(current_task.interrupt_disable_count != 0);
    std.debug.assert(spinlock.isLockedByCurrent(current_task));

    wait_queue.waiting_tasks.push(&current_task.next_task_node);

    kernel.scheduler.lockScheduler(current_task);
    defer kernel.scheduler.unlockScheduler(current_task);

    kernel.scheduler.block(current_task, spinlock);
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const containers = @import("containers");

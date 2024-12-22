// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const WaitQueue = @This();

waiting_tasks: containers.SinglyLinkedFIFO = .empty,

/// Wake one task from the wait queue.
///
/// Asserts that interrupts are disabled.
pub fn wakeOne(self: *WaitQueue, current_task: *kernel.Task) void {
    const executor = current_task.executor.?;

    std.debug.assert(executor.interrupt_disable_count > 0);

    const task_to_wake_node = self.waiting_tasks.pop() orelse return;
    const task_to_wake = kernel.Task.fromNode(task_to_wake_node);

    kernel.scheduler.lock(current_task);
    defer kernel.scheduler.unlock(current_task);

    kernel.scheduler.queueTask(executor, task_to_wake);
}

/// Add the current task to the wait queue.
///
/// Asserts that the spinlock is locked by the current executor and interrupts are disabled.
pub fn wait(
    self: *WaitQueue,
    current_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
) void {
    const executor = current_task.executor.?;

    std.debug.assert(executor.interrupt_disable_count > 0);
    std.debug.assert(spinlock.isLockedBy(executor.id));

    self.waiting_tasks.push(&current_task.next_task_node);

    kernel.scheduler.lock(current_task);
    defer kernel.scheduler.unlock(current_task);

    kernel.scheduler.block(current_task, spinlock);
}

const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const std = @import("std");
const containers = @import("containers");

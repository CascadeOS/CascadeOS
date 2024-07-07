// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");

const WaitQueue = @This();

waiting_tasks: containers.SinglyLinkedFIFO = .{},

pub fn wakeOne(self: *WaitQueue) void {
    const task_to_wake_node = self.waiting_tasks.pop() orelse return;
    const task_to_wake = kernel.Task.fromNode(task_to_wake_node);

    const scheduler_held = kernel.scheduler.acquireScheduler();
    defer scheduler_held.release();

    kernel.scheduler.queueTask(scheduler_held, task_to_wake);
}

pub fn wait(self: *WaitQueue, current_task: *kernel.Task, spinlock_held: kernel.sync.TicketSpinLock.Held) void {
    self.waiting_tasks.push(&current_task.next_task_node);

    const scheduler_held = kernel.scheduler.acquireScheduler();
    defer scheduler_held.release();

    kernel.scheduler.block(scheduler_held, spinlock_held);
}

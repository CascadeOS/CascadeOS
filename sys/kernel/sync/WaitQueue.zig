// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const WaitQueue = @This();

waiting_tasks: containers.SinglyLinkedFIFO = .empty,

pub fn wakeOne(self: *WaitQueue, context: *kernel.Context) void {
    const task_to_wake_node = self.waiting_tasks.pop() orelse return;
    const task_to_wake = kernel.Task.fromNode(task_to_wake_node);

    const held = kernel.scheduler.lock(context);
    defer held.unlock();

    kernel.scheduler.queueTask(context, task_to_wake);
}

pub fn wait(
    self: *WaitQueue,
    context: *kernel.Context,
    current_task: *kernel.Task,
    spinlock_held: kernel.sync.TicketSpinLock.Held,
) void {
    self.waiting_tasks.push(&current_task.next_task_node);

    const held = kernel.scheduler.lock(context);
    defer held.unlock();

    kernel.scheduler.block(context, spinlock_held);
}

const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const std = @import("std");
const containers = @import("containers");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const WaitQueue = @This();

waiting_tasks: containers.SinglyLinkedFIFO = .{},

pub fn wakeOne(self: *WaitQueue, exclusion: kernel.sync.InterruptExclusion) void {
    const task_to_wake_node = self.waiting_tasks.pop() orelse return;
    const task_to_wake = kernel.Task.fromNode(task_to_wake_node);

    var scheduler_held = kernel.scheduler.lockScheduler(exclusion);
    defer scheduler_held.unlock();

    kernel.scheduler.queueTask(scheduler_held, task_to_wake);
}

pub fn wait(
    self: *WaitQueue,
    current_task: *kernel.Task,
    spinlock_held: kernel.sync.TicketSpinLock.Held,
) void {
    self.waiting_tasks.push(&current_task.next_task_node);

    var scheduler_held = kernel.scheduler.lockScheduler(spinlock_held.exclusion);
    defer scheduler_held.unlock();

    kernel.scheduler.block(scheduler_held, spinlock_held);
}

const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const std = @import("std");
const containers = @import("containers");

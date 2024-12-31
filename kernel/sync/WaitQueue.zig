// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const WaitQueue = @This();

waiting_tasks: containers.SinglyLinkedFIFO = .empty,

/// Wake one task from the wait queue.
///
/// Asserts that interrupts are disabled.
pub fn wakeOne(self: *WaitQueue, current_task: *kernel.Task) void {
    std.debug.assert(current_task.interrupt_disable_count.load(.monotonic) != 0);

    const task_to_wake_node = self.waiting_tasks.pop() orelse return;
    const task_to_wake = kernel.Task.fromNode(task_to_wake_node);
    _ = task_to_wake;

    core.panic("IMPLEMENT SCHEDULER", null);
}

/// Add the current task to the wait queue.
///
/// Asserts that the spinlock is locked by the current executor and interrupts are disabled.
pub fn wait(
    self: *WaitQueue,
    current_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
) void {
    std.debug.assert(!current_task.is_idle_task); // block during idle
    std.debug.assert(current_task.interrupt_disable_count.load(.monotonic) != 0);

    const executor = current_task.state.running;
    std.debug.assert(spinlock.isLockedBy(executor.id));

    self.waiting_tasks.push(&current_task.next_task_node);

    core.panic("IMPLEMENT SCHEDULER", null);
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const containers = @import("containers");

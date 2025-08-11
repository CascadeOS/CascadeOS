// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const WaitQueue = @This();

waiting_tasks: core.containers.FIFO = .{},

/// Access the first task in the wait queue.
///
/// Does not remove the task from the wait queue.
///
/// Not thread-safe.
pub fn firstTask(wait_queue: *WaitQueue) ?*kernel.Task {
    const node = wait_queue.waiting_tasks.first_node orelse return null;
    return kernel.Task.fromNode(node);
}

/// Removes the first task from the wait queue.
///
/// Not thread-safe.
pub fn popFirst(wait_queue: *WaitQueue) ?*kernel.Task {
    const node = wait_queue.waiting_tasks.pop() orelse return null;
    return kernel.Task.fromNode(node);
}

/// Wake one task from the wait queue.
///
/// Asserts that the spinlock is locked by the current executor and interrupts are disabled.
pub fn wakeOne(
    wait_queue: *WaitQueue,
    current_task: *kernel.Task,
    spinlock: *const kernel.sync.TicketSpinLock,
    scheduler_locked: core.LockState,
) void {
    std.debug.assert(current_task.interrupt_disable_count != 0);
    std.debug.assert(spinlock.isLockedByCurrent(current_task));

    const task_to_wake_node = wait_queue.waiting_tasks.pop() orelse return;
    const task_to_wake = kernel.Task.fromNode(task_to_wake_node);

    std.debug.assert(task_to_wake.state == .blocked);
    task_to_wake.state = .ready;

    switch (scheduler_locked) {
        .unlocked => kernel.scheduler.lockScheduler(current_task),
        .locked => std.debug.assert(kernel.scheduler.isLockedByCurrent(current_task)),
    }
    defer switch (scheduler_locked) {
        .unlocked => kernel.scheduler.unlockScheduler(current_task),
        .locked => {},
    };

    kernel.scheduler.queueTask(current_task, task_to_wake);
}

/// Add the current task to the wait queue.
///
/// The spinlock will be unlocked upon return.
///
/// Asserts that the spinlock is locked by the current executor and interrupts are disabled.
pub fn wait(
    wait_queue: *WaitQueue,
    current_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
) void {
    std.debug.assert(current_task.interrupt_disable_count != 0);
    std.debug.assert(spinlock.isLockedByCurrent(current_task));

    wait_queue.waiting_tasks.append(&current_task.next_task_node);

    kernel.scheduler.lockScheduler(current_task);
    defer kernel.scheduler.unlockScheduler(current_task);

    kernel.scheduler.drop(current_task, .{
        .action = struct {
            fn action(_: *kernel.Task, old_task: *kernel.Task, arg: usize) void {
                const inner_spinlock: *kernel.sync.TicketSpinLock = @ptrFromInt(arg);

                old_task.state = .blocked;
                old_task.spinlocks_held -= 1;
                old_task.interrupt_disable_count -= 1;

                inner_spinlock.unsafeUnlock();
            }
        }.action,
        .arg = @intFromPtr(spinlock),
    });
}

const kernel = @import("kernel");

const core = @import("core");
const std = @import("std");

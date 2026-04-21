// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const cascade = @import("cascade");
const core = @import("core");

const WaitQueue = @This();

waiting_tasks: core.containers.FIFO = .{},

/// Access the first task in the wait queue.
///
/// Does not remove the task from the wait queue.
///
/// Not thread-safe.
pub fn firstTask(wait_queue: *WaitQueue) ?*cascade.Task {
    const node = wait_queue.waiting_tasks.first_node orelse return null;
    return .fromNode(node);
}

/// Removes the first task from the wait queue.
///
/// Not thread-safe.
pub fn popFirst(wait_queue: *WaitQueue) ?*cascade.Task {
    const node = wait_queue.waiting_tasks.pop() orelse return null;
    return .fromNode(node);
}

/// Wake one task from the wait queue.
///
/// Asserts that the spinlock is locked by the current executor and interrupts are disabled.
pub fn wakeOne(
    wait_queue: *WaitQueue,
    spinlock: *const cascade.sync.TicketSpinLock,
) void {
    if (core.is_debug) {
        std.debug.assert(cascade.Task.Current.get().task.interrupt_disable_count.load(.acquire) != 0);
        std.debug.assert(spinlock.isLockedByCurrent());
    }

    const task_to_wake_node = wait_queue.waiting_tasks.pop() orelse return;
    const task_to_wake: *cascade.Task = .fromNode(task_to_wake_node);

    task_to_wake.wakeFromBlocked();
}

/// Add the current task to the wait queue.
///
/// The spinlock will be unlocked upon return.
///
/// Asserts that the spinlock is locked by the current executor and interrupts are disabled.
pub fn wait(
    wait_queue: *WaitQueue,
    spinlock: *cascade.sync.TicketSpinLock,
) void {
    const current_task: cascade.Task.Current = .get();

    if (core.is_debug) {
        std.debug.assert(current_task.task.interrupt_disable_count.load(.acquire) != 0);
        std.debug.assert(spinlock.isLockedByCurrent());
    }

    wait_queue.waiting_tasks.append(&current_task.task.next_task_node);

    var scheduler_handle: cascade.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();

    scheduler_handle = scheduler_handle.block(
        .{
            .action = struct {
                fn action(old_task: *cascade.Task, arg: usize) void {
                    const inner_spinlock: *cascade.sync.TicketSpinLock = @ptrFromInt(arg);

                    old_task.state = .blocked;
                    old_task.spinlocks_held -= 1;
                    _ = old_task.interrupt_disable_count.fetchSub(1, .acq_rel);

                    inner_spinlock.unsafeUnlock();
                }
            }.action,
            .arg = @intFromPtr(spinlock),
        },
    );
}

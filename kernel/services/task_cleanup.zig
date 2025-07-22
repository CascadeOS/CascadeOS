// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be cleaned up by the task cleanup service.
pub fn queueTaskForCleanup(
    current_task: *Task,
    task: *Task,
    scheduler_locked: core.LockState,
) void {
    std.debug.assert(current_task != task);
    std.debug.assert(task.state == .dropped);

    if (task.state.dropped.queued_for_cleanup.cmpxchgStrong(
        false,
        true,
        .acq_rel,
        .acquire,
    ) != null) {
        // someone else already queued this task for cleanup
        return;
    }

    log.verbose("queueing {f} for cleanup", .{task});

    globals.incoming.prepend(&task.next_task_node);
    wake(current_task, scheduler_locked);
}

/// Wake up the task cleanup service if it is blocked waiting for work.
pub fn wake(
    current_task: *Task,
    scheduler_locked: core.LockState,
) void {
    if (globals.task_waiting.cmpxchgStrong(
        true,
        false,
        .acq_rel,
        .monotonic,
    ) != null) return;
    std.debug.assert(globals.task_cleanup_task.state == .blocked);

    // the task cleanup service was blocked waiting for work

    globals.task_cleanup_task.state = .ready;

    switch (scheduler_locked) {
        .unlocked => {
            kernel.scheduler.lockScheduler(current_task);
            defer kernel.scheduler.unlockScheduler(current_task);

            kernel.scheduler.queueTask(current_task, globals.task_cleanup_task);
        },
        .locked => kernel.scheduler.queueTask(current_task, globals.task_cleanup_task),
    }
}

fn execute(current_task: *Task, _: usize, _: usize) noreturn {
    std.debug.assert(current_task == globals.task_cleanup_task);
    std.debug.assert(current_task.interrupt_disable_count == 0);
    std.debug.assert(current_task.preemption_disable_count == 0);
    std.debug.assert(current_task.preemption_skipped == false);
    std.debug.assert(current_task.spinlocks_held == 0);
    std.debug.assert(kernel.arch.interrupts.areEnabled());

    while (true) {
        while (globals.incoming.popFirst()) |node| {
            const task: *Task = .fromNode(node);
            std.debug.assert(task.state == .dropped);
            std.debug.assert(task.state.dropped.queued_for_cleanup.load(.monotonic));

            const tasks_lock, const tasks = switch (task.context) {
                .kernel => .{ &kernel.kernel_tasks_lock, &kernel.kernel_tasks },
                .user => |process| .{ &process.tasks_lock, &process.tasks },
            };

            task.state.dropped.queued_for_cleanup.store(false, .release);

            {
                tasks_lock.writeLock(current_task);
                defer tasks_lock.writeUnlock(current_task);

                if (task.reference_count.load(.acquire) != 0) {
                    @branchHint(.unlikely);
                    // someone has acquired a reference to the task after it was queued for cleanup
                    log.verbose("{f} still has references", .{task});
                    continue;
                }

                if (task.state.dropped.queued_for_cleanup.swap(true, .acq_rel)) {
                    @branchHint(.unlikely);
                    // someone has requeued this task for cleanup
                    log.verbose("{f} has been requeued for cleanup", .{task});
                    continue;
                }

                // the task is no longer referenced so we can safely destroy it
                if (!tasks.swapRemove(task)) @panic("task not found in tasks");
            }

            // this log must happen before the process reference count is decremented
            log.debug("destroying {f}", .{task});

            switch (task.context) {
                .kernel => {},
                .user => |process| {
                    task.context = .{ .user = undefined };
                    process.decrementReferenceCount(current_task, .unlocked);
                },
            }

            Task.internal.destroy(current_task, task);
        }

        kernel.scheduler.lockScheduler(current_task);
        defer kernel.scheduler.unlockScheduler(current_task);

        if (!globals.incoming.isEmpty()) continue;

        kernel.scheduler.drop(current_task, .{
            .action = struct {
                fn action(old_task: *kernel.Task, _: ?*anyopaque) void {
                    old_task.state = .blocked;
                    globals.task_waiting.store(true, .release);
                }
            }.action,
            .context = null,
        });
    }
}

const globals = struct {
    // initialized during `init.initializeTaskCleanupService`
    var task_cleanup_task: *Task = undefined;

    /// True if the task cleanup service is blocked waiting for work.
    ///
    /// initialized during `init.initializeTaskCleanupService`
    var task_waiting: std.atomic.Value(bool) = undefined;

    var incoming: core.containers.AtomicSinglyLinkedList = .{};
};

pub const init = struct {
    pub fn initializeTaskCleanupService(current_task: *kernel.Task) !void {
        globals.task_cleanup_task = try Task.createKernelTask(current_task, .{
            .name = try .fromSlice("task cleanup"),
            .start_function = execute,
            .arg1 = undefined,
            .arg2 = undefined,
        });
        globals.task_cleanup_task.state = .blocked;
        globals.task_waiting = .init(true);
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const Task = kernel.Task;
const log = kernel.debug.log.scoped(.task_cleanup);

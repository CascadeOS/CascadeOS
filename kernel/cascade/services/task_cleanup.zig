// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const log = cascade.debug.log.scoped(.task_cleanup);

/// Queues a task to be cleaned up by the task cleanup service.
pub fn queueTaskForCleanup(
    current_task: *cascade.Task,
    task: *Task,
) void {
    if (core.is_debug) {
        std.debug.assert(current_task != task);
        std.debug.assert(task.state == .dropped);
    }

    if (task.state.dropped.queued_for_cleanup.cmpxchgStrong(
        false,
        true,
        .acq_rel,
        .acquire,
    ) != null) {
        @panic("already queued for cleanup");
    }

    log.verbose(current_task, "queueing {f} for cleanup", .{task});

    globals.incoming.prepend(&task.next_task_node);
    globals.parker.unpark(current_task);
}

fn execute(current_task: *cascade.Task, _: usize, _: usize) noreturn {
    if (core.is_debug) {
        std.debug.assert(current_task == globals.task_cleanup_task);
        std.debug.assert(current_task.interrupt_disable_count == 0);
        std.debug.assert(current_task.spinlocks_held == 0);
        std.debug.assert(!current_task.scheduler_locked);
        std.debug.assert(arch.interrupts.areEnabled());
    }

    while (true) {
        while (globals.incoming.popFirst()) |node| {
            handleTask(
                current_task,
                .fromNode(node),
            );
        }

        globals.parker.park(current_task);
    }
}

fn handleTask(current_task: *cascade.Task, task: *Task) void {
    if (core.is_debug) {
        std.debug.assert(task.state == .dropped);
        std.debug.assert(task.state.dropped.queued_for_cleanup.load(.monotonic));
    }

    const tasks_lock, const tasks = switch (task.environment) {
        .kernel => .{ &cascade.globals.kernel_tasks_lock, &cascade.globals.kernel_tasks },
        .user => |process| .{ &process.tasks_lock, &process.tasks },
    };

    task.state.dropped.queued_for_cleanup.store(false, .release);

    {
        tasks_lock.writeLock(current_task);
        defer tasks_lock.writeUnlock(current_task);

        if (task.reference_count.load(.acquire) != 0) {
            @branchHint(.unlikely);
            // someone has acquired a reference to the task after it was queued for cleanup
            log.verbose(current_task, "{f} still has references", .{task});
            return;
        }

        if (task.state.dropped.queued_for_cleanup.swap(true, .acq_rel)) {
            @branchHint(.unlikely);
            // someone has requeued this task for cleanup
            log.verbose(current_task, "{f} has been requeued for cleanup", .{task});
            return;
        }

        // the task is no longer referenced so we can safely destroy it
        if (!tasks.swapRemove(task)) @panic("task not found in tasks");
    }

    // this log must happen before the process reference count is decremented
    log.debug(current_task, "destroying {f}", .{task});

    switch (task.environment) {
        .kernel => {},
        .user => |process| {
            task.environment = .{ .user = undefined };
            process.decrementReferenceCount(current_task);
        },
    }

    Task.internal.destroy(current_task, task);
}

const globals = struct {
    // initialized during `init.initializeTaskCleanupService`
    var task_cleanup_task: *Task = undefined;

    /// Parker used to block the task cleanup service.
    ///
    /// initialized during `init.initializeTaskCleanupService`
    var parker: cascade.sync.Parker = undefined;

    var incoming: core.containers.AtomicSinglyLinkedList = .{};
};

pub const init = struct {
    pub fn initializeTaskCleanupService(current_task: *cascade.Task) !void {
        globals.task_cleanup_task = try Task.createKernelTask(current_task, .{
            .name = try .fromSlice("task cleanup"),
            .function = execute,
        });

        globals.parker = .withParkedTask(globals.task_cleanup_task);
    }
};

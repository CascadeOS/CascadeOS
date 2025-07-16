// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be cleaned up by the task cleanup service.
pub fn queueTaskForCleanup(current_task: *Task, task: *Task) void {
    std.debug.assert(current_task != task);
    std.debug.assert(task.state == .dropped);

    log.debug("queueing {f} for cleanup", .{task});

    if (task.state.dropped.queued_for_cleanup.cmpxchgStrong(
        false,
        true,
        .acq_rel,
        .acquire,
    ) != null) {
        // someone else already queued this task for cleanup
        return;
    }

    globals.incoming.prepend(&task.next_task_node);

    globals.wait_queue_lock.lock(current_task);
    defer globals.wait_queue_lock.unlock(current_task);
    globals.wait_queue.wakeOne(current_task, &globals.wait_queue_lock);
}

/// Attempt to pull the task cleanup task out of the wait queue.
///
/// If the task is returned its state is guaranteed to be `.ready`.
///
/// This is intended to be called from the scheduler only.
pub fn schedulerMaybeGetTaskCleanupTask(current_task: *Task) ?*Task {
    if (!globals.wait_queue_lock.tryLock(current_task)) {
        return null;
    }

    const cleanup_service_task = globals.wait_queue.popFirst() orelse {
        globals.wait_queue_lock.unlock(current_task);
        return null;
    };
    globals.wait_queue_lock.unlock(current_task);

    std.debug.assert(cleanup_service_task == globals.task_cleanup_task);
    cleanup_service_task.state = .ready;

    return cleanup_service_task;
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

            switch (task.context) {
                .kernel => {
                    kernel.kernel_tasks_lock.writeLock(current_task);
                    defer kernel.kernel_tasks_lock.writeUnlock(current_task);

                    if (task.reference_count.load(.acquire) != 0) {
                        task.state.dropped.queued_for_cleanup.store(false, .release);
                        continue;
                    }

                    if (!kernel.kernel_tasks.swapRemove(task)) @panic("task not found in kernel tasks");
                },
                .user => @panic("TODO: implement user task cleanup"),
            }

            log.debug("destroying {f}", .{task});

            switch (task.context) {
                .kernel => {},
                .user => @panic("TODO: implement user task cleanup"),
            }

            Task.internal.destroy(current_task, task);
        }

        globals.wait_queue_lock.lock(current_task);
        if (globals.incoming.first.load(.acquire) == null) {
            // incoming queue is empty
            globals.wait_queue_lock.unlock(current_task);
            continue;
        }
        globals.wait_queue.wait(current_task, &globals.wait_queue_lock);
    }
}

const globals = struct {
    // initialized during `init.initializeTaskCleanupService`
    var task_cleanup_task: *Task = undefined;

    // TODO: switch to a single atomic variable rather than a full wait queue for only one task
    var wait_queue_lock: kernel.sync.TicketSpinLock = .{};
    var wait_queue: kernel.sync.WaitQueue = .{};

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
        globals.wait_queue.waiting_tasks.append(
            &globals.task_cleanup_task.next_task_node,
        );
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const Task = kernel.Task;
const log = kernel.debug.log.scoped(.task_cleanup);

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be cleaned up by the task cleanup service.
pub fn queueTaskForCleanup(current_task: *Task, task: *Task) void {
    std.debug.assert(current_task != task);
    std.debug.assert(task.state == .dropped);

    log.debug("queueing {f} for cleanup", .{task});

    globals.wait_queue_lock.lock(current_task);
    defer globals.wait_queue_lock.unlock(current_task);

    if (!task.state.dropped.queued_for_cleanup) {
        globals.incoming.push(&task.state.dropped.node.next);
        task.state.dropped.queued_for_cleanup = true;
    }

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
        while (globals.incoming.pop()) |node| {
            const task: *Task = Task.State.Dropped.taskFromNode(.fromNextNode(node));
            std.debug.assert(task.state == .dropped);

            switch (task.context) {
                .kernel => {
                    kernel.kernel_tasks_lock.writeLock(current_task);
                    defer kernel.kernel_tasks_lock.writeUnlock(current_task);

                    if (!kernel.kernel_tasks.swapRemove(task)) @panic("task not found in kernel tasks");
                },
                .user => @panic("TODO: implement user task cleanup"),
            }

            globals.to_clean.append(&task.state.dropped.node);
        }

        if (globals.to_clean.first) |first| {
            @branchHint(.likely);
            var opt_node: ?*containers.SingleNode = &first.next;

            while (opt_node) |node| {
                const double_node: *containers.DoubleNode = .fromNextNode(node);
                const task: *Task = Task.State.Dropped.taskFromNode(double_node);

                if (task.reference_count.load(.acquire) != 0) {
                    opt_node = node.next;
                    continue;
                }

                log.debug("destroying {f}", .{task});

                switch (task.context) {
                    .kernel => {},
                    .user => @panic("TODO: implement user task cleanup"),
                }

                opt_node = double_node.next.next;
                globals.to_clean.remove(double_node);

                Task.internal.destroy(current_task, task);
            }
        }

        if (!globals.incoming.isEmpty()) continue;
        globals.wait_queue_lock.lock(current_task);
        if (!globals.incoming.isEmpty()) {
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

    var incoming: containers.AtomicSinglyLinkedLIFO = .empty;
    var to_clean: containers.DoublyLinkedList = .empty;
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
        globals.wait_queue.waiting_tasks.push(
            &globals.task_cleanup_task.next_task_node,
        );
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");
const Task = kernel.Task;
const log = kernel.debug.log.scoped(.task_cleanup);

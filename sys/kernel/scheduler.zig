// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be run by the scheduler.
///
/// This function must be called with the scheduler lock held.
pub fn queueTask(task: *kernel.Task) void {
    std.debug.assert(lock.current_holder == arch.getCurrentExecutor().id);
    std.debug.assert(task.next_task_node.next == null);

    task.state = .ready;
    ready_to_run.push(&task.next_task_node);
}

/// Yield execution to the scheduler.
///
/// This function must be called with the scheduler lock held.
pub fn yield(comptime mode: enum { requeue, drop }) void {
    const executor = arch.getCurrentExecutor();
    std.debug.assert(lock.current_holder == executor.id);

    const new_task_node = ready_to_run.pop() orelse {
        switch (mode) {
            .requeue => return, // no tasks to run
            .drop => {
                if (executor.current_task) |current_task| {
                    std.debug.assert(current_task.state == .running);
                    log.debug("dropping {}", .{current_task});
                    current_task.state = .dropped;
                }

                switchToIdle(executor, executor.current_task);
                return;
            },
        }
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(new_task.state == .ready);

    if (executor.current_task) |current_task| {
        std.debug.assert(current_task != new_task);
        std.debug.assert(current_task.state == .running);
        // TODO: reinstate these
        // std.debug.assert(current_task.preemption_disable_count == 0);
        // std.debug.assert(current_task.preemption_skipped == false);

        switch (mode) {
            .requeue => {
                log.debug("yielding {}", .{current_task});
                queueTask(current_task);
            },
            .drop => {
                log.debug("dropping {}", .{current_task});
                current_task.state = .dropped;
            },
        }

        switchToTaskFromTask(executor, current_task, new_task);
    } else {
        switchToTaskFromIdle(executor, new_task);
        unreachable;
    }
}

fn switchToIdle(executor: *kernel.Executor, opt_current_task: ?*kernel.Task) void {
    log.debug("no tasks to run, switching to idle", .{});

    executor.current_task = null;

    if (opt_current_task) |current_task| {
        arch.scheduling.prepareForJumpToIdleFromTask(executor, current_task);
    }

    arch.scheduling.callZeroArgs(opt_current_task, executor.scheduler_stack, idle) catch |err| {
        switch (err) {
            // the scheduler stack should be big enough
            error.StackOverflow => core.panic("insufficent space on the scheduler stack", null),
        }
    };
}

fn switchToTaskFromIdle(executor: *kernel.Executor, new_task: *kernel.Task) noreturn {
    log.debug("switching to {} from idle", .{new_task});

    std.debug.assert(new_task.next_task_node.next == null);

    executor.current_task = new_task;
    new_task.state = .running;

    arch.scheduling.prepareForJumpToTaskFromIdle(executor, new_task);
    arch.scheduling.jumpToTaskFromIdle(new_task);
    unreachable;
}

fn switchToTaskFromTask(executor: *kernel.Executor, current_task: *kernel.Task, new_task: *kernel.Task) void {
    log.debug("switching to {} from {}", .{ new_task, current_task });

    std.debug.assert(new_task.next_task_node.next == null);

    executor.current_task = new_task;
    new_task.state = .running;

    arch.scheduling.prepareForJumpToTaskFromTask(executor, current_task, new_task);
    arch.scheduling.jumpToTaskFromTask(current_task, new_task);
}

fn idle() callconv(.C) noreturn {
    lock.unlock();

    log.debug("entering idle", .{});

    const executor = arch.getCurrentExecutor();
    std.debug.assert(executor.interrupt_disable_count == 1);

    // TODO: correctly handle `interrupt_disable_count`
    executor.interrupt_disable_count -= 1;
    arch.interrupts.enableInterrupts();

    while (true) {
        if (!ready_to_run.isEmpty()) {
            lock.lock();
            defer lock.unlock();
            if (!ready_to_run.isEmpty()) {
                yield(.requeue);
            }
        }

        arch.halt();
    }
}

pub var lock: kernel.sync.TicketSpinLock = .{};
var ready_to_run: containers.SinglyLinkedFIFO = .{};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const containers = @import("containers");
const log = kernel.log.scoped(.scheduler);

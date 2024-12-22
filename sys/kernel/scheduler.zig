// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be run by the scheduler.
///
/// Must be called with the scheduler lock held.
pub fn queueTask(executor: *kernel.Executor, task: *kernel.Task) void {
    std.debug.assert(task.next_task_node.next == null);
    std.debug.assert(!task.is_idle_task); // cannot queue an idle task

    std.debug.assert(globals.lock.isLockedBy(executor.id));

    task.state = .ready;
    globals.ready_to_run.push(&task.next_task_node);
}

/// Maybe preempt the current task.
///
/// The scheduler lock must be *not* be held.
pub fn maybePreempt(current_task: *kernel.Task) void {
    if (current_task.preemption_disable_count != 0) {
        current_task.preemption_skipped = true;
        log.debug("preemption skipped for {}", .{current_task});
        return;
    }

    current_task.incrementInterruptDisable();
    defer current_task.decrementInterruptDisable();

    std.debug.assert(!globals.lock.isLockedBy(current_task.executor.?.id));

    globals.lock.lock(current_task);
    defer globals.lock.unlock(current_task);

    current_task.preemption_skipped = false;

    if (globals.ready_to_run.isEmpty()) return;

    yield(current_task, .requeue);
}

/// Yield execution to the scheduler.
///
/// This function must be called with the scheduler lock held.
pub fn yield(current_task: *kernel.Task, comptime mode: enum { requeue, drop }) void {
    const executor = current_task.executor.?;

    std.debug.assert(globals.lock.isLockedBy(executor.id));
    std.debug.assert(current_task.state == .running);

    const new_task_node = globals.ready_to_run.pop() orelse {
        switch (mode) {
            .requeue => return, // no tasks to run
            .drop => {
                std.debug.assert(!current_task.is_idle_task); // drop during idle

                log.debug("dropping {}", .{current_task});
                current_task.state = .dropped;

                switchToIdle(current_task);
                core.panic("idle returned", null);
            },
        }
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(new_task.state == .ready);

    if (current_task.is_idle_task) {
        switchToTaskFromIdle(current_task, new_task);
        core.panic("idle returned", null);
    }

    std.debug.assert(current_task != new_task);
    std.debug.assert(current_task.state == .running);
    std.debug.assert(current_task.preemption_disable_count == 0);
    std.debug.assert(current_task.preemption_skipped == false);

    switch (mode) {
        .requeue => {
            log.debug("yielding {}", .{current_task});
            queueTask(executor, current_task);
        },
        .drop => {
            log.debug("dropping {}", .{current_task});
            current_task.state = .dropped;
        },
    }

    switchToTaskFromTask(current_task, new_task);
}

/// Blocks the currently running task.
///
/// The `spinlock` is released by this function, the caller is responsible for acquiring it again if necessary.
///
/// This function must be called with the scheduler lock held.
pub fn block(
    current_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
) void {
    const executor = current_task.executor.?;

    std.debug.assert(globals.lock.isLockedBy(executor.id));

    std.debug.assert(!current_task.is_idle_task); // block during idle

    std.debug.assert(current_task.state == .running);
    std.debug.assert(current_task.preemption_disable_count == 0);
    std.debug.assert(current_task.preemption_skipped == false);

    log.debug("blocking {}", .{current_task});
    current_task.state = .blocked;

    const new_task_node = globals.ready_to_run.pop() orelse {
        switchToIdleWithLock(current_task, spinlock);
        return;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(current_task != new_task);
    std.debug.assert(new_task.state == .ready);

    switchToTaskFromTaskWithLock(current_task, new_task, spinlock);
}

fn switchToIdle(current_task: *kernel.Task) void {
    std.debug.assert(!current_task.is_idle_task);

    const executor = current_task.executor.?;

    arch.scheduling.prepareForJumpToIdleFromTask(executor, current_task);

    current_task.executor = null;
    executor.idle_task.state = .running;
    executor.current_task = &executor.idle_task;

    arch.scheduling.callZeroArgs(
        current_task,
        executor.idle_task.stack,
        idle,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => core.panic("insufficent space on the idle task stack", null),
        }
    };
}

fn switchToIdleWithLock(
    current_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
) void {
    const static = struct {
        fn idleEntryWithLock(
            inner_spinlock: *kernel.sync.TicketSpinLock,
        ) callconv(.C) noreturn {
            inner_spinlock.unsafeUnlock();
            idle();
            core.panic("idle returned", null);
        }
    };

    std.debug.assert(!current_task.is_idle_task);

    const executor = current_task.executor.?;

    arch.scheduling.prepareForJumpToIdleFromTask(executor, current_task);

    current_task.executor = null;
    executor.idle_task.state = .running;
    executor.current_task = &executor.idle_task;

    arch.scheduling.callOneArgs(
        current_task,
        executor.idle_task.stack,
        spinlock,
        static.idleEntryWithLock,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => core.panic("insufficent space on the idle task stack", null),
        }
    };
}

fn switchToTaskFromIdle(current_task: *kernel.Task, new_task: *kernel.Task) noreturn {
    std.debug.assert(current_task.is_idle_task);

    log.debug("switching to {} from idle", .{new_task});

    std.debug.assert(new_task.next_task_node.next == null);

    const executor = current_task.executor.?;

    arch.scheduling.prepareForJumpToTaskFromIdle(executor, new_task);

    executor.current_task = new_task;
    new_task.state = .running;
    new_task.executor = executor;
    executor.idle_task.state = .ready;

    arch.scheduling.jumpToTaskFromIdle(new_task);
    core.panic("task returned", null);
}

fn switchToTaskFromTask(current_task: *kernel.Task, new_task: *kernel.Task) void {
    std.debug.assert(!current_task.is_idle_task);
    std.debug.assert(!new_task.is_idle_task);

    log.debug("switching to {} from {}", .{ new_task, current_task });

    std.debug.assert(new_task.next_task_node.next == null);

    const executor = current_task.executor.?;

    arch.scheduling.prepareForJumpToTaskFromTask(executor, current_task, new_task);

    current_task.executor = null;
    executor.current_task = new_task;
    new_task.executor = executor;
    new_task.state = .running;

    arch.scheduling.jumpToTaskFromTask(current_task, new_task);
}

fn switchToTaskFromTaskWithLock(
    current_task: *kernel.Task,
    new_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
) void {
    const static = struct {
        fn switchToTaskWithLock(
            inner_spinlock: *kernel.sync.TicketSpinLock,
            new_task_inner: *kernel.Task,
        ) callconv(.C) noreturn {
            inner_spinlock.unlock(new_task_inner);
            arch.scheduling.jumpToTaskFromIdle(new_task_inner);
            core.panic("task returned", null);
        }
    };

    std.debug.assert(!current_task.is_idle_task);
    std.debug.assert(!new_task.is_idle_task);

    log.debug("switching to {} from {} with a lock", .{ new_task, current_task });

    std.debug.assert(new_task.next_task_node.next == null);

    const executor = current_task.executor.?;

    arch.scheduling.prepareForJumpToTaskFromTask(executor, current_task, new_task);

    current_task.executor = null;
    executor.current_task = new_task;
    new_task.executor = executor;
    new_task.state = .running;

    arch.scheduling.callTwoArgs(
        current_task,
        executor.idle_task.stack,
        spinlock,
        new_task,
        static.switchToTaskWithLock,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => core.panic("insufficent space on the idle task stack", null),
        }
    };
}

fn idle() callconv(.C) noreturn {
    const current_task = blk: {
        const executor = arch.rawGetCurrentExecutor();
        const current_task = executor.current_task;
        std.debug.assert(current_task.executor == executor);
        std.debug.assert(current_task == &executor.idle_task);

        break :blk current_task;
    };

    globals.lock.unlock(current_task);

    log.debug("entering idle", .{});

    current_task.decrementInterruptDisable();
    std.debug.assert(current_task.executor == null);
    std.debug.assert(current_task.preemption_disable_count == 0);

    while (true) {
        {
            current_task.incrementInterruptDisable();
            defer current_task.decrementInterruptDisable();

            globals.lock.lock(current_task);
            defer globals.lock.unlock(current_task);

            if (!globals.ready_to_run.isEmpty()) {
                yield(current_task, .requeue);
            }
        }

        arch.halt();
    }
}

pub fn lock(current_task: *kernel.Task) void {
    return globals.lock.lock(current_task);
}

pub fn unlock(current_task: *kernel.Task) void {
    globals.lock.unlock(current_task);
}

const globals = struct {
    var lock: kernel.sync.TicketSpinLock = .{};
    var ready_to_run: containers.SinglyLinkedFIFO = .empty;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const containers = @import("containers");
const log = kernel.log.scoped(.scheduler);

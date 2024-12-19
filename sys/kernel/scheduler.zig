// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be run by the scheduler.
///
/// Must be called with the scheduler lock held.
pub fn queueTask(context: *kernel.Context, task: *kernel.Task) void {
    std.debug.assert(task.next_task_node.next == null);
    std.debug.assert(!task.is_idle_task); // cannot queue an idle task

    std.debug.assert(globals.lock.isLockedBy(context.executor.?.id));

    task.state = .ready;
    globals.ready_to_run.push(&task.next_task_node);
}

/// Maybe preempt the current task.
///
/// The scheduler lock must be *not* be held.
pub fn maybePreempt(context: *kernel.Context) void {
    if (context.preemption_disable_count != 0) {
        context.task.preemption_skipped = true;
        log.debug("preemption skipped for {}", .{context.task});
        return;
    }

    log.debug("preempting {}", .{context.task});

    const held = lock(context);
    defer held.unlock();

    context.task.preemption_skipped = false;

    if (globals.ready_to_run.isEmpty()) return;

    yield(context, .requeue);
}

/// Yield execution to the scheduler.
///
/// This function must be called with the scheduler lock held.
pub fn yield(context: *kernel.Context, comptime mode: enum { requeue, drop }) void {
    std.debug.assert(globals.lock.isLockedBy(context.executor.?.id));

    const current_task = context.task;
    std.debug.assert(current_task.state == .running);

    const new_task_node = globals.ready_to_run.pop() orelse {
        switch (mode) {
            .requeue => return, // no tasks to run
            .drop => {
                std.debug.assert(!current_task.is_idle_task); // drop during idle

                log.debug("dropping {}", .{current_task});
                current_task.state = .dropped;

                switchToIdle(context, current_task);
                core.panic("idle returned", null);
            },
        }
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(new_task.state == .ready);

    if (current_task.is_idle_task) {
        switchToTaskFromIdle(context, new_task);
        core.panic("idle returned", null);
    }

    std.debug.assert(current_task != new_task);
    std.debug.assert(current_task.state == .running);
    std.debug.assert(current_task.preemption_disable_count == 0);
    std.debug.assert(current_task.preemption_skipped == false);

    switch (mode) {
        .requeue => {
            log.debug("yielding {}", .{current_task});
            queueTask(context, current_task);
        },
        .drop => {
            log.debug("dropping {}", .{current_task});
            current_task.state = .dropped;
        },
    }

    switchToTaskFromTask(context, current_task, new_task);
}

/// Blocks the currently running task.
///
/// The `spinlock` is released by this function, the caller is responsible for acquiring it again if necessary.
///
/// This function must be called with the scheduler lock held.
pub fn block(
    context: *kernel.Context,
    spinlock_held: kernel.sync.TicketSpinLock.Held,
) void {
    std.debug.assert(globals.lock.isLockedBy(context.executor.?.id));

    const current_task = context.task;
    std.debug.assert(!current_task.is_idle_task); // block during idle

    std.debug.assert(current_task.state == .running);
    std.debug.assert(current_task.preemption_disable_count == 0);
    std.debug.assert(current_task.preemption_skipped == false);

    log.debug("blocking {}", .{current_task});
    current_task.state = .blocked;

    const new_task_node = globals.ready_to_run.pop() orelse {
        switchToIdleWithLock(context, current_task, spinlock_held);
        return;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(current_task != new_task);
    std.debug.assert(new_task.state == .ready);

    switchToTaskFromTaskWithLock(context, current_task, new_task, spinlock_held);
}

fn switchToIdle(context: *kernel.Context, current_task: *kernel.Task) void {
    std.debug.assert(!current_task.is_idle_task);

    arch.scheduling.prepareForJumpToIdleFromTask(context, current_task);

    const executor = context.executor.?;

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

    executor.current_context = context;
}

fn switchToIdleWithLock(
    context: *kernel.Context,
    current_task: *kernel.Task,
    spinlock_held: kernel.sync.TicketSpinLock.Held,
) void {
    const static = struct {
        fn idleWithLock(
            spinlock: *kernel.sync.TicketSpinLock,
        ) callconv(.C) noreturn {
            spinlock.unsafeRelease();
            idle();
            core.panic("idle returned", null);
        }
    };

    std.debug.assert(!current_task.is_idle_task);

    arch.scheduling.prepareForJumpToIdleFromTask(context, current_task);

    const executor = context.executor.?;

    executor.idle_task.state = .running;
    executor.current_task = &executor.idle_task;

    arch.scheduling.callOneArgs(
        current_task,
        executor.idle_task.stack,
        spinlock_held.spinlock,
        static.idleWithLock,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => core.panic("insufficent space on the idle task stack", null),
        }
    };

    executor.current_context = context;
}

fn switchToTaskFromIdle(context: *kernel.Context, new_task: *kernel.Task) noreturn {
    std.debug.assert(context.task.is_idle_task);

    log.debug("switching to {} from idle", .{new_task});

    std.debug.assert(new_task.next_task_node.next == null);

    arch.scheduling.prepareForJumpToTaskFromIdle(context, new_task);

    const executor = context.executor.?;

    executor.current_task = new_task;
    new_task.state = .running;
    executor.idle_task.state = .ready;

    arch.scheduling.jumpToTaskFromIdle(new_task);
    core.panic("task returned", null);
}

fn switchToTaskFromTask(context: *kernel.Context, current_task: *kernel.Task, new_task: *kernel.Task) void {
    std.debug.assert(!current_task.is_idle_task);
    std.debug.assert(!new_task.is_idle_task);

    log.debug("switching to {} from {}", .{ new_task, current_task });

    std.debug.assert(new_task.next_task_node.next == null);

    arch.scheduling.prepareForJumpToTaskFromTask(context, current_task, new_task);

    const executor = context.executor.?;

    executor.current_task = new_task;
    new_task.state = .running;

    arch.scheduling.jumpToTaskFromTask(current_task, new_task);

    executor.current_context = context;
}

fn switchToTaskFromTaskWithLock(
    context: *kernel.Context,
    current_task: *kernel.Task,
    new_task: *kernel.Task,
    spinlock_held: kernel.sync.TicketSpinLock.Held,
) void {
    const static = struct {
        fn switchToTaskWithLock(
            spinlock: *kernel.sync.TicketSpinLock,
            new_task_inner: *kernel.Task,
        ) callconv(.C) noreturn {
            spinlock.unsafeRelease();
            arch.scheduling.jumpToTaskFromIdle(new_task_inner);
            core.panic("task returned", null);
        }
    };

    std.debug.assert(!current_task.is_idle_task);
    std.debug.assert(!new_task.is_idle_task);

    log.debug("switching to {} from {} with a lock", .{ new_task, current_task });

    std.debug.assert(new_task.next_task_node.next == null);

    arch.scheduling.prepareForJumpToTaskFromTask(context, current_task, new_task);

    const executor = context.executor.?;

    executor.current_task = new_task;
    new_task.state = .running;

    arch.scheduling.callTwoArgs(
        current_task,
        executor.idle_task.stack,
        spinlock_held.spinlock,
        new_task,
        static.switchToTaskWithLock,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => core.panic("insufficent space on the idle task stack", null),
        }
    };

    executor.current_context = context;
}

fn idle() callconv(.C) noreturn {
    var context: kernel.Context = undefined;
    context.createNew(arch.rawGetCurrentExecutor());

    std.debug.assert(globals.lock.isLockedBy(context.executor.?.id));

    globals.lock.unsafeRelease();

    log.debug("entering idle", .{});
    context.decrementInterruptDisable();

    while (true) {
        {
            const held = lock(&context);
            defer held.unlock();

            if (!globals.ready_to_run.isEmpty()) {
                yield(&context, .requeue);
            }
        }

        arch.halt();
    }
}

pub fn lock(context: *kernel.Context) kernel.sync.TicketSpinLock.Held {
    return globals.lock.lock(context);
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

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be run by the scheduler.
///
/// Must be called with the scheduler lock held.
pub fn queueTask(current_task: *kernel.Task, task: *kernel.Task) void {
    std.debug.assert(globals.lock.isLockedByCurrent(current_task));
    std.debug.assert(task.state == .ready);
    std.debug.assert(!task.is_idle_task); // cannot queue an idle task

    globals.ready_to_run.push(&task.next_task_node);
}

/// Maybe preempt the current task.
///
/// The scheduler lock must *not* be held.
pub fn maybePreempt(current_task: *kernel.Task) void {
    std.debug.assert(current_task.state == .running);
    std.debug.assert(current_task.spinlocks_held == 0);

    if (current_task.preemption_disable_count != 0) {
        current_task.preemption_skipped = true;
        return;
    }

    lockScheduler(current_task);
    defer unlockScheduler(current_task);

    current_task.preemption_skipped = false;

    if (globals.ready_to_run.isEmpty()) return;

    log.verbose("preempting {}", .{current_task});

    yield(current_task, .requeue);
}

/// Yields the current task.
///
/// Must be called with the scheduler lock held.
pub fn yield(current_task: *kernel.Task, comptime mode: enum { requeue, drop }) void {
    std.debug.assert(globals.lock.isLockedByCurrent(current_task));
    std.debug.assert(current_task.spinlocks_held == 1); // the scheduler lock is held

    std.debug.assert(current_task.preemption_disable_count == 0);
    std.debug.assert(current_task.preemption_skipped == false);

    const new_task_node = globals.ready_to_run.pop() orelse {
        switch (mode) {
            .requeue => return, // no tasks to run
            .drop => {
                std.debug.assert(!current_task.is_idle_task); // drop during idle

                log.verbose("dropping {}", .{current_task});

                switchToIdle(current_task, .dropped);
                @panic("idle returned");
            },
        }
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(new_task.state == .ready);

    if (current_task.is_idle_task) {
        switchToTaskFromIdle(current_task, new_task);
        @panic("idle returned");
    }

    std.debug.assert(current_task != new_task);

    const current_task_new_state = blk: switch (mode) {
        .requeue => {
            log.verbose("yielding {}", .{current_task});
            // can't call `queueTask` here because the `current_task.state` is not yet set to `.ready`
            globals.ready_to_run.push(&current_task.next_task_node);
            break :blk .ready;
        },
        .drop => {
            log.verbose("dropping {}", .{current_task});
            break :blk .dropped;
        },
    };

    switchToTaskFromTask(current_task, new_task, current_task_new_state);
}

/// Blocks the currently running task.
///
/// The `spinlock` is released by this function, the caller is responsible for acquiring it again if necessary.
///
/// This function must be called with the scheduler lock held.
pub fn block(current_task: *kernel.Task, spinlock: *kernel.sync.TicketSpinLock) void {
    std.debug.assert(current_task.spinlocks_held == 2); // the scheduler lock and `spinlock` is held

    std.debug.assert(globals.lock.isLockedByCurrent(current_task));

    std.debug.assert(!current_task.is_idle_task); // block during idle

    log.verbose("blocking {}", .{current_task});

    const new_task_node = globals.ready_to_run.pop() orelse {
        switchToIdleWithLock(current_task, spinlock, .blocked);
        return;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(current_task != new_task);
    std.debug.assert(new_task.state == .ready);

    switchToTaskFromTaskWithLock(current_task, new_task, spinlock, .blocked);
}

fn switchToIdle(current_task: *kernel.Task, current_task_new_state: kernel.Task.State) void {
    std.debug.assert(current_task.spinlocks_held == 1); // the scheduler lock is held

    std.debug.assert(!current_task.is_idle_task);
    const executor = current_task.state.running;

    kernel.arch.scheduling.prepareForJumpToIdleFromTask(executor, current_task);

    current_task.state = current_task_new_state;

    executor.idle_task.state = .{ .running = executor };
    executor.current_task = &executor.idle_task;

    kernel.arch.scheduling.callOneArgs(
        current_task,
        executor.idle_task.stack,
        &executor.idle_task,
        idle,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => @panic("insufficent space on the idle task stack"),
        }
    };
}

fn switchToIdleWithLock(
    current_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
    current_task_new_state: kernel.Task.State,
) void {
    const static = struct {
        fn idleEntryWithLock(
            inner_spinlock: *kernel.sync.TicketSpinLock,
            idle_task: *kernel.Task,
        ) callconv(.C) noreturn {
            std.debug.assert(idle_task.is_idle_task);

            inner_spinlock.unsafeUnlock();

            idle(idle_task);
            @panic("idle returned");
        }
    };

    std.debug.assert(current_task.spinlocks_held == 2); // the scheduler lock and `spinlock` is held
    std.debug.assert(!current_task.is_idle_task);
    const executor = current_task.state.running;

    kernel.arch.scheduling.prepareForJumpToIdleFromTask(executor, current_task);

    current_task.state = current_task_new_state;
    current_task.spinlocks_held = 1; // `spinlock` is unlocked in `static.idleEntryWithLock`

    executor.idle_task.state = .{ .running = executor };
    executor.current_task = &executor.idle_task;

    kernel.arch.scheduling.callTwoArgs(
        current_task,
        executor.idle_task.stack,
        spinlock,
        &executor.idle_task,
        static.idleEntryWithLock,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => @panic("insufficent space on the idle task stack"),
        }
    };
}

fn switchToTaskFromIdle(current_task: *kernel.Task, new_task: *kernel.Task) void {
    std.debug.assert(current_task.spinlocks_held == 1); // the scheduler lock is held
    std.debug.assert(current_task.is_idle_task);

    log.verbose("switching to {} from idle", .{new_task});

    std.debug.assert(new_task.next_task_node.next == null);

    const executor = current_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromIdle(executor, new_task);

    new_task.state = .{ .running = executor };
    executor.current_task = new_task;
    executor.idle_task.state = .ready;

    kernel.arch.scheduling.jumpToTaskFromIdle(new_task);
    @panic("task returned");
}

fn switchToTaskFromTask(current_task: *kernel.Task, new_task: *kernel.Task, current_task_new_state: kernel.Task.State) void {
    std.debug.assert(current_task.spinlocks_held == 1); // the scheduler lock is held
    std.debug.assert(!current_task.is_idle_task);
    std.debug.assert(!new_task.is_idle_task);

    log.verbose("switching to {} from {}", .{ new_task, current_task });

    std.debug.assert(new_task.next_task_node.next == null);

    const executor = current_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(executor, current_task, new_task);

    current_task.state = current_task_new_state;

    new_task.state = .{ .running = executor };
    executor.current_task = new_task;

    kernel.arch.scheduling.jumpToTaskFromTask(current_task, new_task);
}

fn switchToTaskFromTaskWithLock(
    current_task: *kernel.Task,
    new_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
    current_task_new_state: kernel.Task.State,
) void {
    const static = struct {
        fn switchToTaskWithLock(
            inner_spinlock: *kernel.sync.TicketSpinLock,
            new_task_inner: *kernel.Task,
        ) callconv(.C) noreturn {
            inner_spinlock.unsafeUnlock();

            kernel.arch.scheduling.jumpToTaskFromIdle(new_task_inner);
            @panic("task returned");
        }
    };

    std.debug.assert(current_task.spinlocks_held == 2); // the scheduler lock and `spinlock` is held

    std.debug.assert(!current_task.is_idle_task);
    std.debug.assert(!new_task.is_idle_task);

    log.verbose("switching to {} from {} with a lock", .{ new_task, current_task });

    std.debug.assert(new_task.next_task_node.next == null);

    const executor = current_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(executor, current_task, new_task);

    current_task.state = current_task_new_state;
    current_task.spinlocks_held = 1; // `spinlock` is unlocked in `static.switchToTaskWithLock`

    new_task.state = .{ .running = executor };
    executor.current_task = new_task;

    kernel.arch.scheduling.callTwoArgs(
        current_task,
        executor.idle_task.stack,
        spinlock,
        new_task,
        static.switchToTaskWithLock,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => @panic("insufficent space on the idle task stack"),
        }
    };
}

pub fn lockScheduler(current_task: *kernel.Task) void {
    globals.lock.lock(current_task);
}

pub fn unlockScheduler(current_task: *kernel.Task) void {
    globals.lock.unlock(current_task);
}

pub fn newTaskEntry(
    current_task: *kernel.Task,
    /// must be a function compatible with `kernel.arch.scheduling.NewTaskFunction`
    target_function_addr: *const anyopaque,
    task_arg1: u64,
    task_arg2: u64,
) callconv(.C) noreturn {
    globals.lock.unlock(current_task);

    const func: kernel.arch.scheduling.NewTaskFunction = @ptrCast(target_function_addr);
    func(current_task, task_arg1, task_arg2);
    @panic("task returned to entry point");
}

fn idle(current_task: *kernel.Task) callconv(.c) noreturn {
    globals.lock.unlock(current_task);

    log.debug("entering idle", .{});

    while (true) {
        {
            lockScheduler(current_task);
            defer unlockScheduler(current_task);

            if (!globals.ready_to_run.isEmpty()) {
                yield(current_task, .requeue);
            }
        }

        kernel.arch.halt();
    }
}

const globals = struct {
    var lock: kernel.sync.TicketSpinLock = .{};
    var ready_to_run: containers.SinglyLinkedFIFO = .empty;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");
const log = kernel.debug.log.scoped(.scheduler);

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Queues a task to be run by the scheduler.
///
/// Must be called with the scheduler lock held.
pub fn queueTask(current_task: *kernel.Task, task: *kernel.Task) void {
    std.debug.assert(globals.lock.isLockedByCurrent(current_task));
    std.debug.assert(task.state == .ready);
    std.debug.assert(!task.isIdleTask()); // cannot queue an idle task

    globals.ready_to_run.append(&task.next_task_node);
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

    log.verbose("preempting {f}", .{current_task});

    yield(current_task);
}

/// Yields the current task.
///
/// Must be called with the scheduler lock held.
pub fn yield(current_task: *kernel.Task) void {
    std.debug.assert(globals.lock.isLockedByCurrent(current_task));
    std.debug.assert(current_task.spinlocks_held == 1); // the scheduler lock is held

    std.debug.assert(current_task.preemption_disable_count == 0);
    std.debug.assert(current_task.preemption_skipped == false);

    const new_task_node = globals.ready_to_run.pop() orelse
        return; // no tasks to run

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(new_task.state == .ready);

    if (current_task.isIdleTask()) {
        log.verbose("leaving idle", .{});

        switchToTaskFromIdleYield(current_task, new_task);
        @panic("idle returned");
    }

    std.debug.assert(current_task != new_task);

    log.verbose("yielding {f}", .{current_task});

    globals.ready_to_run.append(&current_task.next_task_node);

    switchToTaskFromTaskYield(current_task, new_task);
}

/// Blocks the currently running task.
///
/// The `spinlock` is released by this function, the caller is responsible for acquiring it again if necessary.
///
/// This function must be called with the scheduler lock held.
pub fn block(current_task: *kernel.Task, spinlock: *kernel.sync.TicketSpinLock) void {
    std.debug.assert(current_task.spinlocks_held == 2); // the scheduler lock and `spinlock` is held
    std.debug.assert(current_task.interrupt_disable_count >= 2);
    std.debug.assert(globals.lock.isLockedByCurrent(current_task));
    std.debug.assert(!current_task.isIdleTask()); // block during idle

    const new_task_node = globals.ready_to_run.pop() orelse {
        switchToIdleBlock(current_task, spinlock);
        return;
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(current_task != new_task);
    std.debug.assert(new_task.state == .ready);

    switchToTaskFromTaskBlock(
        current_task,
        new_task,
        spinlock,
    );
}

/// Drops the current task.
///
/// Must be called with the scheduler lock held.
pub fn drop(current_task: *kernel.Task) noreturn {
    std.debug.assert(!current_task.isIdleTask()); // drop during idle

    std.debug.assert(globals.lock.isLockedByCurrent(current_task));
    std.debug.assert(current_task.spinlocks_held == 1); // the scheduler lock is held

    std.debug.assert(current_task.preemption_disable_count == 0);
    std.debug.assert(current_task.preemption_skipped == false);

    log.verbose("dropping {f}", .{current_task});

    const new_task_node = globals.ready_to_run.pop() orelse new_task_node: {
        if (kernel.services.task_cleanup.schedulerMaybeGetTaskCleanupTask(current_task)) |cleanup_service_task| {
            break :new_task_node &cleanup_service_task.next_task_node;
        }

        switchToIdleDrop(current_task);
        @panic("idle returned");
    };

    const new_task = kernel.Task.fromNode(new_task_node);
    std.debug.assert(new_task.state == .ready);
    std.debug.assert(current_task != new_task);

    switchToTaskFromTaskDrop(current_task, new_task);
    @panic("dropped task resumed");
}

fn switchToIdle(
    current_executor: *kernel.Executor,
    current_task: *kernel.Task,
) void {
    const static = struct {
        fn idleEntry(
            idle_task_addr: usize,
        ) callconv(.c) noreturn {
            const idle_task: *kernel.Task = @ptrFromInt(idle_task_addr);

            std.debug.assert(idle_task.isIdleTask());
            globals.lock.unlock(idle_task);

            idle(idle_task);
            @panic("idle returned");
        }
    };

    std.debug.assert(current_task.spinlocks_held == 1); // the scheduler lock is held
    std.debug.assert(!current_task.isIdleTask());

    log.verbose("switching from {f} to idle", .{current_task});

    kernel.arch.scheduling.prepareForJumpToIdleFromTask(current_executor, current_task);

    current_executor.idle_task.state = .{ .running = current_executor };
    current_executor.current_task = &current_executor.idle_task;

    kernel.arch.scheduling.callOneArgs(
        current_task,
        current_executor.idle_task.stack,
        @intFromPtr(&current_executor.idle_task),
        static.idleEntry,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => @panic("insufficent space on the idle task stack"),
        }
    };
}

fn switchToIdleBlock(
    old_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
) void {
    const static = struct {
        fn idleEntryBlock(
            inner_spinlock_addr: usize,
            idle_task_addr: usize,
        ) callconv(.c) noreturn {
            const inner_spinlock: *kernel.sync.TicketSpinLock = @ptrFromInt(inner_spinlock_addr);
            const idle_task: *kernel.Task = @ptrFromInt(idle_task_addr);

            std.debug.assert(idle_task.isIdleTask());

            inner_spinlock.unsafeUnlock();
            globals.lock.unlock(idle_task);

            idle(idle_task);
            @panic("idle returned");
        }
    };

    std.debug.assert(old_task.spinlocks_held == 2); // the scheduler lock and `spinlock` is held
    std.debug.assert(!old_task.isIdleTask());

    log.verbose("switching from {f} to idle and blocking", .{old_task});

    const current_executor = old_task.state.running;

    kernel.arch.scheduling.prepareForJumpToIdleFromTask(current_executor, old_task);

    old_task.spinlocks_held = 1; // `spinlock` is unlocked in `static.idleEntryBlock`
    old_task.decrementInterruptDisable(); // as `unsafeUnlock` is used we need to decrement the interrupt disable count separately

    current_executor.idle_task.state = .{ .running = current_executor };
    current_executor.current_task = &current_executor.idle_task;

    old_task.state = .blocked;

    kernel.arch.scheduling.callTwoArgs(
        old_task,
        current_executor.idle_task.stack,
        @intFromPtr(spinlock),
        @intFromPtr(&current_executor.idle_task),
        static.idleEntryBlock,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => @panic("insufficent space on the idle task stack"),
        }
    };
}

fn switchToIdleDrop(old_task: *kernel.Task) void {
    const static = struct {
        fn idleEntryDrop(
            task_to_drop_addr: usize,
            idle_task_addr: usize,
        ) callconv(.c) noreturn {
            const task_to_drop: *kernel.Task = @ptrFromInt(task_to_drop_addr);
            const idle_task: *kernel.Task = @ptrFromInt(idle_task_addr);

            std.debug.assert(idle_task.isIdleTask());
            idle_task.incrementPreemptionDisable();
            globals.lock.unlock(idle_task);

            task_to_drop.decrementReferenceCount(idle_task);
            idle_task.decrementPreemptionDisable();

            idle(idle_task);
            @panic("idle returned");
        }
    };

    std.debug.assert(old_task.state == .running);
    std.debug.assert(old_task.spinlocks_held == 1); // the scheduler lock is held
    std.debug.assert(!old_task.isIdleTask());

    log.verbose("switching from {f} to idle and dropping", .{old_task});

    const current_executor = old_task.state.running;

    kernel.arch.scheduling.prepareForJumpToIdleFromTask(current_executor, old_task);

    current_executor.idle_task.state = .{ .running = current_executor };
    current_executor.current_task = &current_executor.idle_task;

    old_task.state = .{ .dropped = .{} };

    kernel.arch.scheduling.callTwoArgs(
        old_task,
        current_executor.idle_task.stack,
        @intFromPtr(old_task),
        @intFromPtr(&current_executor.idle_task),
        static.idleEntryDrop,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => @panic("insufficent space on the idle task stack"),
        }
    };
}

fn switchToTaskFromIdleYield(current_task: *kernel.Task, new_task: *kernel.Task) void {
    std.debug.assert(current_task.spinlocks_held == 1); // the scheduler lock is held
    std.debug.assert(current_task.isIdleTask());
    std.debug.assert(new_task.next_task_node.next == null);

    log.verbose("switching from idle to {f}", .{new_task});

    const executor = current_task.state.running;
    std.debug.assert(&executor.idle_task == current_task);

    kernel.arch.scheduling.prepareForJumpToTaskFromIdle(executor, new_task);

    new_task.state = .{ .running = executor };
    executor.current_task = new_task;
    executor.idle_task.state = .ready;

    kernel.arch.scheduling.jumpToTaskFromIdle(new_task);
    @panic("task returned");
}

fn switchToTaskFromTaskYield(
    old_task: *kernel.Task,
    new_task: *kernel.Task,
) void {
    std.debug.assert(old_task.spinlocks_held == 1); // the scheduler lock is held
    std.debug.assert(!old_task.isIdleTask());
    std.debug.assert(!new_task.isIdleTask());
    std.debug.assert(new_task.next_task_node.next == null);

    log.verbose("switching from {f} to {f}", .{ old_task, new_task });

    const current_executor = old_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, new_task);

    new_task.state = .{ .running = current_executor };
    current_executor.current_task = new_task;

    old_task.state = .ready;

    kernel.arch.scheduling.jumpToTaskFromTask(old_task, new_task);
}

fn switchToTaskFromTaskBlock(
    old_task: *kernel.Task,
    new_task: *kernel.Task,
    spinlock: *kernel.sync.TicketSpinLock,
) void {
    const static = struct {
        fn switchToTaskBlock(
            inner_spinlock_addr: usize,
            new_task_inner_addr: usize,
        ) callconv(.c) noreturn {
            const inner_spinlock: *kernel.sync.TicketSpinLock = @ptrFromInt(inner_spinlock_addr);
            const new_task_inner: *kernel.Task = @ptrFromInt(new_task_inner_addr);

            inner_spinlock.unsafeUnlock();

            kernel.arch.scheduling.jumpToTaskFromIdle(new_task_inner);
            @panic("task returned");
        }
    };

    std.debug.assert(old_task.spinlocks_held == 2); // the scheduler lock and `spinlock` is held
    std.debug.assert(!old_task.isIdleTask());
    std.debug.assert(!new_task.isIdleTask());
    std.debug.assert(new_task.next_task_node.next == null);

    log.verbose("switching from {f} to {f} and blocking", .{ old_task, new_task });

    const current_executor = old_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, new_task);

    old_task.spinlocks_held = 1; // `spinlock` is unlocked in `static.switchToTaskBlock`
    old_task.decrementInterruptDisable(); // as `unsafeUnlock` is used we need to decrement the interrupt disable count separately

    new_task.state = .{ .running = current_executor };
    current_executor.current_task = new_task;

    old_task.state = .blocked;

    kernel.arch.scheduling.callTwoArgs(
        old_task,
        current_executor.idle_task.stack,
        @intFromPtr(spinlock),
        @intFromPtr(new_task),
        static.switchToTaskBlock,
    ) catch |err| {
        switch (err) {
            // the idle task stack should be big enough
            error.StackOverflow => @panic("insufficent space on the idle task stack"),
        }
    };
}

fn switchToTaskFromTaskDrop(old_task: *kernel.Task, new_task: *kernel.Task) void {
    const static = struct {
        fn switchToTaskDrop(
            task_to_drop_addr: usize,
            new_task_inner_addr: usize,
        ) callconv(.c) noreturn {
            const task_to_drop: *kernel.Task = @ptrFromInt(task_to_drop_addr);
            const new_task_inner: *kernel.Task = @ptrFromInt(new_task_inner_addr);

            const preemption_skipped = new_task_inner.preemption_skipped;
            new_task_inner.preemption_disable_count += 1;
            globals.lock.unlock(new_task_inner);

            task_to_drop.decrementReferenceCount(new_task_inner);

            globals.lock.lock(new_task_inner);
            new_task_inner.preemption_disable_count -= 1;
            new_task_inner.preemption_skipped = preemption_skipped;

            kernel.arch.scheduling.jumpToTaskFromIdle(new_task_inner);
            @panic("task returned");
        }
    };

    std.debug.assert(old_task.state == .running);
    std.debug.assert(old_task.spinlocks_held == 1); // the scheduler lock is held
    std.debug.assert(!old_task.isIdleTask());
    std.debug.assert(!new_task.isIdleTask());
    std.debug.assert(new_task.next_task_node.next == null);

    log.verbose("switching from {f} to {f} and dropping", .{ old_task, new_task });

    const current_executor = old_task.state.running;

    kernel.arch.scheduling.prepareForJumpToTaskFromTask(current_executor, old_task, new_task);

    new_task.state = .{ .running = current_executor };
    current_executor.current_task = new_task;

    old_task.state = .{ .dropped = .{} };

    kernel.arch.scheduling.callTwoArgs(
        old_task,
        current_executor.idle_task.stack,
        @intFromPtr(old_task),
        @intFromPtr(new_task),
        static.switchToTaskDrop,
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
    task_arg1: usize,
    task_arg2: usize,
) callconv(.c) noreturn {
    globals.lock.unlock(current_task);

    const func: kernel.arch.scheduling.NewTaskFunction = @ptrCast(target_function_addr);
    func(current_task, task_arg1, task_arg2);
    @panic("task returned to entry point");
}

fn idle(current_task: *kernel.Task) callconv(.c) noreturn {
    log.verbose("entering idle", .{});

    while (true) {
        {
            lockScheduler(current_task);
            defer unlockScheduler(current_task);

            if (!globals.ready_to_run.isEmpty()) {
                yield(current_task);
            }
        }

        kernel.arch.halt();
    }
}

const globals = struct {
    var lock: kernel.sync.TicketSpinLock = .{};
    var ready_to_run: core.containers.FIFO = .{};
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.scheduler);

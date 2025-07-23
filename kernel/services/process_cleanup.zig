// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn queueProcessForCleanup(
    current_task: *kernel.Task,
    process: *kernel.Process,
    scheduler_locked: core.LockState,
) void {
    if (process.queued_for_cleanup.cmpxchgStrong(
        false,
        true,
        .acq_rel,
        .acquire,
    ) != null) {
        // someone else already queued this process for cleanup
        return;
    }

    log.verbose("queueing {f} for cleanup", .{process});

    globals.incoming.prepend(&process.cleanup_node);
    wake(current_task, scheduler_locked);
}

/// Wake up the process cleanup service if it is blocked waiting for work.
pub fn wake(
    current_task: *kernel.Task,
    scheduler_locked: core.LockState,
) void {
    globals.parker.unpark(current_task, scheduler_locked);
}

fn execute(current_task: *kernel.Task, _: usize, _: usize) noreturn {
    std.debug.assert(current_task == globals.process_cleanup_task);
    std.debug.assert(current_task.interrupt_disable_count == 0);
    std.debug.assert(current_task.preemption_disable_count == 0);
    std.debug.assert(current_task.preemption_skipped == false);
    std.debug.assert(current_task.spinlocks_held == 0);
    std.debug.assert(kernel.arch.interrupts.areEnabled());

    while (true) {
        while (globals.incoming.popFirst()) |node| {
            handleProcess(
                current_task,
                @fieldParentPtr("cleanup_node", node),
            );
        }

        kernel.scheduler.lockScheduler(current_task);
        defer kernel.scheduler.unlockScheduler(current_task);

        if (!globals.incoming.isEmpty()) continue;

        globals.parker.park(current_task, .locked);
    }
}

fn handleProcess(current_task: *kernel.Task, process: *kernel.Process) void {
    std.debug.assert(process.queued_for_cleanup.load(.monotonic));

    process.queued_for_cleanup.store(false, .release);

    {
        kernel.processes_lock.writeLock(current_task);
        defer kernel.processes_lock.writeUnlock(current_task);

        if (process.reference_count.load(.acquire) != 0) {
            @branchHint(.unlikely);
            // someone has acquired a reference to the process after it was queued for cleanup
            log.verbose("{f} still has references", .{process});
            return;
        }

        if (process.queued_for_cleanup.swap(true, .acq_rel)) {
            @branchHint(.unlikely);
            // someone has requeued this process for cleanup
            log.verbose("{f} has been requeued for cleanup", .{process});
            return;
        }

        if (!kernel.processes.swapRemove(process)) @panic("process not found in processes");
    }

    kernel.Process.internal.destroy(current_task, process);
}

const globals = struct {
    // initialized during `init.initializeProcessCleanupService`
    var process_cleanup_task: *kernel.Task = undefined;

    /// Parker used to block the process cleanup service.
    ///
    /// initialized during `init.initializeProcessCleanupService`
    var parker: kernel.sync.Parker = undefined;

    var incoming: core.containers.AtomicSinglyLinkedList = .{};
};

pub const init = struct {
    pub fn initializeProcessCleanupService(current_task: *kernel.Task) !void {
        globals.process_cleanup_task = try kernel.Task.createKernelTask(current_task, .{
            .name = try .fromSlice("process cleanup"),
            .start_function = execute,
            .arg1 = undefined,
            .arg2 = undefined,
        });

        globals.parker = .withParkedTask(globals.process_cleanup_task);
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.process_cleanup);

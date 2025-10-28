// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const log = cascade.debug.log.scoped(.process_cleanup);

pub fn queueProcessForCleanup(
    current_task: *cascade.Task,
    process: *cascade.Process,
) void {
    if (process.queued_for_cleanup.cmpxchgStrong(
        false,
        true,
        .acq_rel,
        .acquire,
    ) != null) {
        @panic("already queued for cleanup");
    }

    log.verbose(current_task, "queueing {f} for cleanup", .{process});

    globals.incoming.prepend(&process.cleanup_node);
    globals.parker.unpark(current_task);
}

fn execute(current_task: *cascade.Task, _: usize, _: usize) noreturn {
    if (core.is_debug) {
        std.debug.assert(current_task == globals.process_cleanup_task);
        std.debug.assert(current_task.context.interrupt_disable_count == 0);
        std.debug.assert(current_task.context.spinlocks_held == 0);
        std.debug.assert(!current_task.context.scheduler_locked);
        std.debug.assert(arch.interrupts.areEnabled());
    }

    while (true) {
        while (globals.incoming.popFirst()) |node| {
            handleProcess(
                current_task,
                @fieldParentPtr("cleanup_node", node),
            );
        }

        globals.parker.park(current_task);
    }
}

fn handleProcess(current_task: *cascade.Task, process: *cascade.Process) void {
    if (core.is_debug) std.debug.assert(process.queued_for_cleanup.load(.monotonic));

    process.queued_for_cleanup.store(false, .release);

    {
        cascade.globals.processes_lock.writeLock(current_task);
        defer cascade.globals.processes_lock.writeUnlock(current_task);

        if (process.reference_count.load(.acquire) != 0) {
            @branchHint(.unlikely);
            // someone has acquired a reference to the process after it was queued for cleanup
            log.verbose(current_task, "{f} still has references", .{process});
            return;
        }

        if (process.queued_for_cleanup.swap(true, .acq_rel)) {
            @branchHint(.unlikely);
            // someone has requeued this process for cleanup
            log.verbose(current_task, "{f} has been requeued for cleanup", .{process});
            return;
        }

        if (!cascade.globals.processes.swapRemove(process)) @panic("process not found in processes");
    }

    cascade.Process.internal.destroy(current_task, process);
}

const globals = struct {
    // initialized during `init.initializeProcessCleanupService`
    var process_cleanup_task: *cascade.Task = undefined;

    /// Parker used to block the process cleanup service.
    ///
    /// initialized during `init.initializeProcessCleanupService`
    var parker: cascade.sync.Parker = undefined;

    var incoming: core.containers.AtomicSinglyLinkedList = .{};
};

pub const init = struct {
    pub fn initializeProcessCleanupService(current_task: *cascade.Task) !void {
        globals.process_cleanup_task = try cascade.Task.createKernelTask(current_task, .{
            .name = try .fromSlice("process cleanup"),
            .function = execute,
        });

        globals.parker = .withParkedTask(globals.process_cleanup_task);
    }
};

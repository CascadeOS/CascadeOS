// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn queueProcessForCleanup(
    context: *kernel.Task.Context,
    process: *kernel.Process,
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

    log.verbose(context, "queueing {f} for cleanup", .{process});

    globals.incoming.prepend(&process.cleanup_node);
    globals.parker.unpark(context);
}

fn execute(context: *kernel.Task.Context, _: usize, _: usize) noreturn {
    std.debug.assert(context.task() == globals.process_cleanup_task);
    std.debug.assert(context.interrupt_disable_count == 0);
    std.debug.assert(context.spinlocks_held == 0);
    std.debug.assert(!context.scheduler_locked);
    std.debug.assert(arch.interrupts.areEnabled());

    while (true) {
        while (globals.incoming.popFirst()) |node| {
            handleProcess(
                context,
                @fieldParentPtr("cleanup_node", node),
            );
        }

        globals.parker.park(context);
    }
}

fn handleProcess(context: *kernel.Task.Context, process: *kernel.Process) void {
    std.debug.assert(process.queued_for_cleanup.load(.monotonic));

    process.queued_for_cleanup.store(false, .release);

    {
        kernel.globals.processes_lock.writeLock(context);
        defer kernel.globals.processes_lock.writeUnlock(context);

        if (process.reference_count.load(.acquire) != 0) {
            @branchHint(.unlikely);
            // someone has acquired a reference to the process after it was queued for cleanup
            log.verbose(context, "{f} still has references", .{process});
            return;
        }

        if (process.queued_for_cleanup.swap(true, .acq_rel)) {
            @branchHint(.unlikely);
            // someone has requeued this process for cleanup
            log.verbose(context, "{f} has been requeued for cleanup", .{process});
            return;
        }

        if (!kernel.globals.processes.swapRemove(process)) @panic("process not found in processes");
    }

    kernel.Process.internal.destroy(context, process);
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
    pub fn initializeProcessCleanupService(context: *kernel.Task.Context) !void {
        globals.process_cleanup_task = try kernel.Task.createKernelTask(context, .{
            .name = try .fromSlice("process cleanup"),
            .start_function = execute,
            .arg1 = undefined,
            .arg2 = undefined,
            .kernel_task_type = .normal,
        });

        globals.parker = .withParkedTask(globals.process_cleanup_task);
    }
};

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const log = kernel.debug.log.scoped(.process_cleanup);
const std = @import("std");

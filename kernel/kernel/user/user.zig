// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const kernel = @import("kernel");
const Task = kernel.Task;

pub const elf = @import("elf.zig");
pub const Process = @import("Process.zig");
pub const Thread = @import("Thread.zig");

const log = kernel.debug.log.scoped(.user);

/// Called on syscall.
///
/// Interrupts are enabled.
pub fn onSyscall(current_task: Task.Current, syscall_frame: arch.user.SyscallFrame) void {
    const syscall = syscall_frame.syscall() orelse {
        // TODO: return an error to userspace
        std.debug.panic("invalid syscall\n{f}", .{syscall_frame.arch_specific});
    };

    log.verbose(current_task, "received syscall: {t}", .{syscall});

    switch (syscall) {
        .exit_thread => {
            const scheduler_handle: Task.SchedulerHandle = .get(current_task);
            scheduler_handle.drop(current_task);
            unreachable;
        },
    }
}

pub const init = struct {
    const init_log = kernel.debug.log.scoped(.user_init);

    pub fn initialize(current_task: Task.Current) !void {
        init_log.debug(current_task, "initializing processes", .{});
        try Process.init.initializeProcesses(current_task);

        init_log.debug(current_task, "initializing threads", .{});
        try Thread.init.initializeThreads(current_task);

        try arch.user.init.initialize(current_task);
    }
};

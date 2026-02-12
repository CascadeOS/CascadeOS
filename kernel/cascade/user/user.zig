// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;

pub const elf = @import("elf.zig");
pub const Process = @import("Process.zig");
pub const Thread = @import("Thread.zig");

const log = cascade.debug.log.scoped(.user);

/// Called on syscall.
///
/// Interrupts are disabled on entry.
pub fn onSyscall(syscall_frame: arch.user.SyscallFrame) void {
    if (core.is_debug) {
        const current_task: Task.Current = .get();
        std.debug.assert(current_task.task.interrupt_disable_count == 0);
        std.debug.assert(current_task.task.enable_access_to_user_memory_count == 0);
        std.debug.assert(!arch.interrupts.areEnabled());
    }

    arch.interrupts.enable();

    const syscall = syscall_frame.syscall() orelse {
        // TODO: return an error to userspace
        std.debug.panic("invalid syscall\n{f}", .{syscall_frame});
    };

    log.verbose("received syscall: {t}", .{syscall});

    switch (syscall) {
        .exit_thread => {
            const scheduler_handle: Task.SchedulerHandle = .get();
            scheduler_handle.drop();
            unreachable;
        },
    }
}

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.user_init);

    pub fn initialize() !void {
        try Process.init.initializeProcesses();
        try Thread.init.initializeThreads();
        try arch.user.init.initialize();
    }
};

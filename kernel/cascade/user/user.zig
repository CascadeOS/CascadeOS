// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

pub const elf = @import("elf.zig");
pub const Process = @import("Process.zig");
pub const Thread = @import("Thread.zig");

const log = cascade.debug.log.scoped(.user);

/// Called on syscall.
///
/// Interrupts are disabled on entry.
pub fn onSyscall(syscall_frame: arch.user.SyscallFrame) void {
    if (core.is_debug) {
        const current_task: cascade.Task.Current = .get();
        std.debug.assert(current_task.task.interrupt_disable_count.load(.acquire) == 0);
        std.debug.assert(current_task.task.enable_access_to_user_memory_count.load(.acquire) == 0);
        std.debug.assert(!arch.interrupts.areEnabled());
    }

    arch.interrupts.enable();

    const syscall = syscall_frame.syscall() orelse {
        // TODO: return an error to userspace
        std.debug.panic("invalid syscall\n{f}", .{syscall_frame});
    };

    log.verbose("received syscall: {t}", .{syscall});

    switch (syscall) {
        .exit_current_thread => {
            const scheduler_handle: cascade.Task.Scheduler.Handle = .get();
            scheduler_handle.terminate();
            unreachable;
        },
    }
}

pub const init = struct {
    pub fn initialize() !void {
        try Process.init.initializeProcesses();
        try Thread.init.initializeThreads();
        try arch.user.init.initialize();
    }
};

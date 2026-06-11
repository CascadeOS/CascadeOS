// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");
const user_cascade = @import("user_cascade");

pub const elf = @import("elf.zig");
pub const Process = @import("Process.zig");
pub const Thread = @import("Thread.zig");

const log = cascade.debug.log.scoped(.user);

/// Called on syscall.
///
/// The current task's `interrupt_disable_count` is set to 1 and interrupts are disabled.
pub fn onSyscall(
    current_task: cascade.Task.Current,
    syscall_frame: arch.user.SyscallFrame,
) i64 {
    // enable interrupts
    current_task.decrementInterruptDisable();

    const syscall = syscall_frame.syscall() orelse {
        // TODO: return an error to userspace
        std.debug.panic("invalid syscall\n{f}", .{syscall_frame});
    };

    log.verbose("received syscall: {t}", .{syscall});

    switch (syscall) {
        .thread_exit_current => {
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

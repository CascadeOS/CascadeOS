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
        .debug_print => {
            const range = syscall_frame.getUserRange(.two, .one) orelse return 0;
            const slice = range.byteSlice();

            if (slice.len == 0) {
                @branchHint(.cold);
                return 0;
            }

            const writer = cascade.init.Output.terminal.writer;

            // TODO: remove usage of `init.Output` as this is intended to be disabled by the time userspace is running...
            cascade.init.Output.lock.lock();
            defer cascade.init.Output.lock.unlock();

            ret: {
                const process: *const Process = .from(current_task.task);

                writer.print("{f}: ", .{process}) catch {
                    @branchHint(.cold);
                    break :ret;
                };

                const ends_with_newline = blk: {
                    current_task.enableAccessToUserMemory();
                    defer current_task.disableAccessToUserMemory();

                    // TODO: implement safe access to user memory so page faults can be handled correctly
                    writer.writeAll(range.byteSlice()) catch {
                        @branchHint(.cold);
                        break :blk false;
                    };

                    break :blk slice[slice.len - 1] == '\n';
                };

                if (!ends_with_newline) writer.writeByte('\n') catch {
                    @branchHint(.cold);
                    break :ret;
                };
            }

            writer.flush() catch {
                @branchHint(.cold);
            };

            return 0;
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

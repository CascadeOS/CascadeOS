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
            const full_source = (syscall_frame.getUserRange(.two, .one) orelse return 0).toVirtualRange();

            if (full_source.size.equal(.zero)) return 0;

            const writer = cascade.init.Output.terminal.writer;
            if (core.is_debug) std.debug.assert(writer.buffer.len != 0); // assumed by below loop to be non-zero

            const full_destination = cascade.KernelVirtualRange.fromSlice(u8, writer.buffer).toVirtualRange();
            var bytes_copied: core.Size = .zero;

            // TODO: remove usage of `init.Output` as this is intended to be disabled by the time userspace is running...
            //       and printing logs during page faults that occur during the safe memcpy will deadlock
            cascade.init.Output.lock.lock();
            defer {
                writer.end = 0;
                cascade.init.Output.lock.unlock();
            }
            if (core.is_debug) std.debug.assert(writer.end == 0);

            const process: *const Process = .from(current_task.task);
            writer.print("{f}: ", .{process}) catch {
                @branchHint(.cold);
                return 0;
            };

            var last_copy = false;

            while (!last_copy) {
                const bytes_to_copy: core.Size = .from(
                    @min(full_source.size.subtract(bytes_copied).value, writer.buffer.len - writer.end),
                    .byte,
                );

                if (!cascade.mem.safe.memcpy(.{
                    .destination = full_destination.subslice(
                        .from(writer.end, .byte),
                        bytes_to_copy,
                    ),
                    .source = full_source.subslice(bytes_copied, bytes_to_copy),
                })) {
                    @branchHint(.cold);
                    return 0;
                }

                bytes_copied.addInPlace(bytes_to_copy);
                last_copy = bytes_copied.greaterThanOrEqual(full_source.size);

                writer.end += bytes_to_copy.value;
                defer writer.end = 0;

                if (last_copy and writer.buffer[writer.end - 1] != '\n') writer.writeByte('\n') catch {
                    @branchHint(.cold);
                    return 0;
                };

                writer.flush() catch {
                    @branchHint(.cold);
                    return 0;
                };
            }

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

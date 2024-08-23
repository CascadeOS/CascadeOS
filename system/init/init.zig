// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn initStage1() !noreturn {
    // get output up and running as soon as possible
    arch.init.setupEarlyOutput();
    arch.init.writeToEarlyOutput(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");

    // now that early output is ready, we can switch to the single executor panic
    kernel.debug.panic_impl = singleExecutorPanic;

    const bootstrap_executor, const bootstrap_executor_id = blk: {
        const id: kernel.Executor.Id = @enumFromInt(kernel.system.executors.len + 1);
        break :blk .{ try kernel.system.executors.addOne(), id };
    };
    bootstrap_executor.* = .{
        .id = bootstrap_executor_id,
    };

    arch.init.prepareBootstrapExecutor(bootstrap_executor);
    arch.init.loadExecutor(bootstrap_executor);

    core.panic("NOT IMPLEMENTED", null);
}

fn singleExecutorPanic(
    msg: []const u8,
    error_return_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void {
    const static = struct {
        var panicked = std.atomic.Value(bool).init(false);
    };

    if (static.panicked.load(.acquire)) {
        arch.init.writeToEarlyOutput("\nPANIC IN PANIC\n");
        return;
    }
    static.panicked.store(true, .release);

    kernel.debug.formatting.printPanic(
        early_output_writer,
        msg,
        error_return_trace,
        return_address,
    ) catch unreachable;
}

const early_output_writer = std.io.Writer(
    void,
    error{},
    struct {
        fn writeFn(_: void, bytes: []const u8) error{}!usize {
            arch.init.writeToEarlyOutput(bytes);
            return bytes.len;
        }
    }.writeFn,
){ .context = {} };

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");

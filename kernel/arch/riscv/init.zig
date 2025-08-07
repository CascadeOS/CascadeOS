// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Read current wallclock time from the standard wallclock source of the current architecture.
///
/// For example on x86_64 this is the TSC.
pub fn getStandardWallclockStartTime() kernel.time.wallclock.Tick {
    return @enumFromInt(lib_riscv.instructions.readTime());
}

/// Attempt to get some form of init output.
pub fn tryGetSerialOutput() ?arch.init.InitOutput {
    if (SBIDebugConsole.detect()) {
        log.debug("using sbi debug console for serial output", .{});
        return .{
            .output = SBIDebugConsole.output,
            .preference = .use,
        };
    }

    return null;
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
    architecture_processor_id: u64,
) void {
    bootstrap_executor.arch_specific = .{
        .hartid = @intCast(architecture_processor_id),
    };
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
    lib_riscv.registers.SupervisorScratch.write(@intFromPtr(executor));
}

const SBIDebugConsole = struct {
    fn detect() bool {
        return sbi.debug_console.available();
    }

    fn writeStr(str: []const u8) void {
        // TODO: figure out how to get `sbi.debug_console.write` to work
        //       as `sbi.debug_console.writeByte` is inefficient

        for (0..str.len) |i| {
            const byte = str[i];

            if (byte == '\n') {
                @branchHint(.unlikely);

                const newline_first_or_only = str.len == 1 or i == 0;

                if (newline_first_or_only or str[i - 1] != '\r') {
                    @branchHint(.likely);
                    sbi.debug_console.writeByte('\r') catch return;
                }
            }

            sbi.debug_console.writeByte(byte) catch return;
        }
    }

    const output: kernel.init.Output = .{
        .writeFn = struct {
            fn writeFn(_: *anyopaque, str: []const u8) void {
                writeStr(str);
            }
        }.writeFn,
        .splatFn = struct {
            fn splatFn(_: *anyopaque, str: []const u8, splat: usize) void {
                for (0..splat) |_| writeStr(str);
            }
        }.splatFn,
        .remapFn = struct {
            fn remapFn(_: *anyopaque, _: *kernel.Task) !void {
                return;
            }
        }.remapFn,
        .context = undefined,
    };
};

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const lib_riscv = @import("riscv");
const log = kernel.debug.log.scoped(.init_riscv);
const riscv = @import("riscv.zig");
const sbi = @import("sbi");
const std = @import("std");

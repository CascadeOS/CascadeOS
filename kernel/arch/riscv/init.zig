// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz

/// Attempt to get some form of init output.
///
/// This function can return an architecture specific output if it is available and if not is expected to call into
/// `kernel.init.Output.tryGetSerialOutputFromGenericSources`.
pub fn tryGetSerialOutput() ?kernel.init.Output {
    return kernel.init.Output.tryGetSerialOutputFromGenericSources();
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
    architecture_processor_id: u64,
) void {
    bootstrap_executor.arch = .{
        .hartid = @intCast(architecture_processor_id),
    };
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
    lib_riscv.registers.SupervisorScratch.write(@intFromPtr(executor));
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const riscv = @import("riscv.zig");
const lib_riscv = @import("riscv");

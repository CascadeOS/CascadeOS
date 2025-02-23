// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz

/// Attempt to register some form of init output.
pub fn tryGetOutput() callconv(core.inline_in_non_debug) ?kernel.init.Output {
    return kernel.init.Output.tryGetOutputFromAcpiTables();
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
    architecture_processor_id: u64,
) void {
    bootstrap_executor.arch = .{
        .mpidr = architecture_processor_id,
    };
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
    lib_arm.registers.TPIDR_EL1.write(@intFromPtr(executor));
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arm = @import("arm.zig");
const lib_arm = @import("arm");

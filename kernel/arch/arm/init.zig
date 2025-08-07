// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Read current wallclock time from the standard wallclock source of the current architecture.
///
/// For example on x86_64 this is the TSC.
pub fn getStandardWallclockStartTime() kernel.time.wallclock.Tick {
    return @enumFromInt(lib_arm.instructions.readPhysicalCount()); // TODO: should this be virtual count?
}

/// Attempt to get some form of init output.
pub fn tryGetSerialOutput() ?arch.init.InitOutput {
    return null;
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
    architecture_processor_id: u64,
) void {
    bootstrap_executor.arch_specific = .{
        .mpidr = architecture_processor_id,
    };
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
    lib_arm.registers.TPIDR_EL1.write(@intFromPtr(executor));
}

const arch = @import("arch");
const kernel = @import("kernel");

const arm = @import("arm.zig");
const core = @import("core");
const lib_arm = @import("arm");
const std = @import("std");

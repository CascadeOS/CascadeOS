// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");
const std = @import("std");

const riscv = @import("riscv.zig");

/// Read current wallclock time from the standard wallclock source of the current architecture.
///
/// For example on x86_64 this is the TSC.
///
/// Non-optional because it is used during early initialization.
pub fn getStandardWallclockStartTime() cascade.time.wallclock.Tick {
    return @enumFromInt(asm ("rdtime %[ret]"
        : [ret] "=r" (-> u64),
    ));
}

/// Attempt to get some form of architecture specific init output if it is available.
///
/// If `memory_system_available` is false, then the memory system has not been initialized so heap allocation and the special heap are
/// not available.
///
/// The first time this function is called `memory_system_available` will be false, this function will be called again after the memory
/// system is initialized with `memory_system_available` set to true, but only if a generic serial output was not available without
/// needing the memory system.
pub fn tryGetSerialOutput(memory_system_available: bool) ?arch.init.InitOutput {
    _ = memory_system_available;

    const sbi_debug_console = @import("sbi_debug_console.zig");

    if (sbi_debug_console.detect()) {
        return .{
            .output = sbi_debug_console.output,
            .preference = .use,
        };
    }

    return null;
}

pub const CaptureSystemInformationOptions = struct {};

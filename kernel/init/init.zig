// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn initStage1() !noreturn {
    kernel.arch.interrupts.disableInterruptsAndHalt();
}

// needs to be accessible from the kernel root file
pub const exportEntryPoints = boot.exportEntryPoints;

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const boot = @import("boot.zig");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn initStage1() !void {
    kernel.arch.init.setupEarlyOutput();

    kernel.debug.setPanicMode(.simple_init_panic);

    kernel.arch.init.writeToEarlyOutput(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");

    core.panic("NOT IMPLEMENTED", null);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel.zig");

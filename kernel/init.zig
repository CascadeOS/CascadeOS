// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.init);

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn kernelInit() !void {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    // now that early output is ready, we can switch to the init panic
    kernel.debug.init.loadInitPanic();

    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        early_output.writeAll(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n") catch {};
    }
}

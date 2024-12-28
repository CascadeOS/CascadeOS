// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn initStage1() !void {
    // we want the direct map to be available as early as possible
    try kernel.mem.init.earlyPartialMemoryLayout();

    kernel.arch.init.setupEarlyOutput();

    kernel.debug.setPanicMode(.simple_init_panic);
    kernel.log.setLogMode(.simple_init_log);

    kernel.arch.init.writeToEarlyOutput(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");

    var bootstrap_executor: kernel.Executor = .{
        .id = .bootstrap,
        .arch = undefined, // set by `arch.init.prepareBootstrapExecutor`
    };

    kernel.arch.init.prepareBootstrapExecutor(&bootstrap_executor);
    kernel.arch.init.loadExecutor(&bootstrap_executor);

    kernel.arch.init.initializeInterrupts();

    core.panic("NOT IMPLEMENTED", null);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.log.scoped(.init);

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

/// Represents the bootstrap cpu during init.
var bootstrap_cpu: kernel.Cpu = .{
    .id = @enumFromInt(0),
    .arch = undefined, // set by `arch.init.prepareBootstrapCpu`
};

const starting_message = "starting CascadeOS " ++ @import("kernel_options").cascade_version ++ "\n";

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn kernelInit() void {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    // we need to get the current cpu loaded early as most code assumes it is available
    kernel.arch.init.prepareBootstrapCpu(&bootstrap_cpu);
    kernel.arch.init.loadCpu(&bootstrap_cpu);

    // now that early output and the bootstrap cpu are loaded, we can switch to the init panic
    kernel.debug.init.loadInitPanic();

    kernel.arch.init.initInterrupts();

    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        early_output.writeAll(starting_message) catch {};
    }
}

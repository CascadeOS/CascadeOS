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

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn kernelInit() !void {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    // we need to get the current cpu loaded early as most code assumes it is available
    kernel.arch.init.prepareBootstrapCpu(&bootstrap_cpu);
    kernel.arch.init.loadCpu(&bootstrap_cpu);

    // ensure any interrupts are handled
    kernel.arch.init.initInterrupts();

    // now that early output and the bootstrap cpu are loaded, we can switch to the init panic
    kernel.debug.init.loadInitPanic();

    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        const starting_message = comptime "starting CascadeOS " ++ @import("kernel_options").cascade_version ++ "\n";
        early_output.writeAll(starting_message) catch {};
    }
}

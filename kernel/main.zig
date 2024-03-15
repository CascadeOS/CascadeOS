// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

/// Represents the bootstrap cpu during init.
var bootstrap_cpu: kernel.Cpu = .{
    .id = @enumFromInt(0),
};

/// Entry point from the bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn kmain() void {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    // we need to get the current cpu loaded early as the panic handler and logging use it
    kernel.arch.init.prepareBootstrapCpu(&bootstrap_cpu);
    kernel.arch.init.loadCpu(&bootstrap_cpu);

    // now that early output and the bootstrap cpu are loaded, we can switch to the init panic
    kernel.debug.init.loadInitPanic();

    // print starting message
    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        early_output.writeAll(comptime "starting CascadeOS " ++ @import("kernel_options").cascade_version ++ "\n") catch {};
    }
}

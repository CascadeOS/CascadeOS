// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

/// Used to represent the bootstrap cpu during initialization.
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
    kernel.arch.init.loadCpu(&bootstrap_cpu);

    // print starting message
    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        early_output.writeAll(comptime "starting CascadeOS " ++ @import("kernel_options").cascade_version ++ "\n") catch {};
    }
}

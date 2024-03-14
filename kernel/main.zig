// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

/// Entry point from the bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn kmain() void {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    // print starting message
    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        early_output.writeAll(comptime "starting CascadeOS " ++ @import("kernel_options").cascade_version ++ "\n") catch {};
    }
}

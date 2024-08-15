// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

comptime {
    kernel.init.exportEntryPoints();
}

pub const std_options: std.Options = .{
    .log_level = kernel.log.log_level,
    .logFn = kernel.log.stdLogImpl,
};

pub const panic = kernel.debug.zigPanic;

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

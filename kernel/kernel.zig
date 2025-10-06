// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const cascade = @import("cascade");

pub const panic = cascade.debug.panic_interface;

pub const std_options: std.Options = .{
    .log_level = cascade.debug.log.log_level.toStd(),
    .logFn = cascade.debug.log.stdLogImpl,
};

comptime {
    @import("boot").exportEntryPoints();
}

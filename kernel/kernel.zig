// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot.zig");
pub const Cpu = @import("Cpu.zig");
pub const debug = @import("debug.zig");
pub const log = @import("log.zig");

comptime {
    _ = &boot; // ensure any entry points or bootloader required symbols are referenced
}

pub const std_options: std.Options = .{
    .log_level = log.log_level,
    .logFn = log.stdLogImpl,
};

pub const panic = debug.zigPanic;

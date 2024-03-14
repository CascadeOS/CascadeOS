// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot.zig");
pub const Cpu = @import("Cpu.zig");
pub const global = @import("global.zig");
pub const log = @import("log.zig");

comptime {
    _ = &boot; // ensure any entry points or bootloader required symbols are referenced
}

pub const std_options: std.Options = .{
    .log_level = log.std_log_level,
    .logFn = log.stdLogImpl,
};

/// Entry point from the Zig language upon a panic.
pub fn panic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address_opt: ?usize,
) noreturn {
    @setCold(true);
    global.panic_impl(msg, stack_trace, return_address_opt);
}

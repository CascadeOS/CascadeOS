// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

pub const arch = @import("arch/arch.zig");
pub const log = @import("log.zig");

export fn _start() callconv(.C) noreturn {
    @call(.never_inline, @import("main.zig").kmain, .{});
    core.panic("kmain returned");
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
    _ = msg;
    _ = stack_trace;
    _ = return_address_opt;

    @setCold(true);
    while (true) {
        arch.spinLoopHint();
    }
}

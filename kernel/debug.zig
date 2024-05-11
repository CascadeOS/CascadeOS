// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

/// Entry point from the Zig language upon a panic.
pub fn zigPanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address_opt: ?usize,
) noreturn {
    _ = msg;
    _ = stack_trace;
    _ = return_address_opt;

    @setCold(true);

    while (true) {
        kernel.arch.interrupts.disableInterruptsAndHalt();
    }
}

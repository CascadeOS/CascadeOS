// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Store of all global state that is required after kernel initialization is complete.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub var panic_impl: *const fn (
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address_opt: ?usize,
) noreturn = noOpPanic;

fn noOpPanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address_opt: ?usize,
) noreturn {
    _ = msg;
    _ = stack_trace;
    _ = return_address_opt;

    while (true) {
        kernel.arch.interrupts.disableInterruptsAndHalt();
    }
}

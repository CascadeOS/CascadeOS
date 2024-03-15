// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

fn printUserPanicMessage(writer: anytype, msg: []const u8) void {
    if (msg.len != 0) {
        writer.writeAll("\nPANIC - ") catch unreachable;

        writer.writeAll(msg) catch unreachable;

        if (msg[msg.len - 1] != '\n') {
            writer.writeByte('\n') catch unreachable;
        }
    } else {
        writer.writeAll("\nPANIC\n") catch unreachable;
    }
}

fn printErrorAndCurrentStackTrace(
    writer: anytype,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void {
    _ = stack_trace;
    _ = return_address;

    writer.writeAll("stack traces unimplemented\n") catch return; // TODO: implement this
}

var panic_impl: *const fn (
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void = init.noOpPanic;

/// Entry point from the Zig language upon a panic.
pub fn zigPanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address_opt: ?usize,
) noreturn {
    @setCold(true);

    kernel.arch.interrupts.disableInterrupts();

    panic_impl(msg, stack_trace, return_address_opt orelse @returnAddress());

    while (true) {
        kernel.arch.interrupts.disableInterruptsAndHalt();
    }
}

pub const init = struct {
    pub fn loadInitializationPanic() void {
        panic_impl = initializationPanic;
    }

    /// Panic handler during kernel initialization.
    fn initializationPanic(
        msg: []const u8,
        stack_trace: ?*const std.builtin.StackTrace,
        return_address: usize,
    ) void {
        if (kernel.arch.init.getEarlyOutput()) |early_output| {
            printUserPanicMessage(early_output, msg);
            printErrorAndCurrentStackTrace(early_output, stack_trace, return_address);
        }
    }

    fn noOpPanic(
        msg: []const u8,
        stack_trace: ?*const std.builtin.StackTrace,
        return_address: usize,
    ) void {
        _ = msg;
        _ = stack_trace;
        _ = return_address;
    }
};

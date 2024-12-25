// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Entry point from the Zig language upon a panic.
fn zigPanic(
    msg: []const u8,
    error_return_trace: ?*const std.builtin.StackTrace,
    return_address_opt: ?usize,
) noreturn {
    @branchHint(.cold);

    _ = return_address_opt;
    _ = error_return_trace;
    _ = msg;

    while (true) {
        kernel.arch.interrupts.disableInterruptsAndHalt();
    }
}

/// Zig panic interface.
pub const Panic = struct {
    pub const call = zigPanic;

    pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        @branchHint(.cold);
        std.debug.panicExtra(null, @returnAddress(), "sentinel mismatch: expected {any}, found {any}", .{
            expected, found,
        });
    }

    pub fn unwrapError(error_return_trace: ?*std.builtin.StackTrace, err: anyerror) noreturn {
        @branchHint(.cold);
        std.debug.panicExtra(error_return_trace, @returnAddress(), "attempt to unwrap error: {s}", .{@errorName(err)});
    }

    pub fn outOfBounds(index: usize, len: usize) noreturn {
        @branchHint(.cold);
        std.debug.panicExtra(null, @returnAddress(), "index out of bounds: index {d}, len {d}", .{ index, len });
    }

    pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        @branchHint(.cold);
        std.debug.panicExtra(null, @returnAddress(), "start index {d} is larger than end index {d}", .{ start, end });
    }

    pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        @branchHint(.cold);
        std.debug.panicExtra(null, @returnAddress(), "access of union field '{s}' while field '{s}' is active", .{
            @tagName(accessed), @tagName(active),
        });
    }

    pub const messages = std.debug.SimplePanic.messages;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel.zig");

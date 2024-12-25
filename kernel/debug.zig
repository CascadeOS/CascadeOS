// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Zig panic interface.
pub const Panic = struct {
    /// Entry point from the Zig language upon a panic.
    pub fn call(
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

    pub const sentinelMismatch = std.debug.FormattedPanic.sentinelMismatch;
    pub const unwrapError = std.debug.FormattedPanic.unwrapError;
    pub const outOfBounds = std.debug.FormattedPanic.outOfBounds;
    pub const startGreaterThanEnd = std.debug.FormattedPanic.startGreaterThanEnd;
    pub const inactiveUnionField = std.debug.FormattedPanic.inactiveUnionField;
    pub const messages = std.debug.FormattedPanic.messages;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel.zig");

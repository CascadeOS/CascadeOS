// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// The panic mode the kernel is in.
///
/// The panic mode will be moved through each mode as the kernel is initialized.
///
/// No modes will be skipped and must be in strict increasing order.
pub const PanicMode = enum(u8) {
    /// Panic does nothing other than halt the executor.
    no_op,
};

pub fn setPanicMode(mode: PanicMode) void {
    if (@intFromEnum(globals.panic_mode) + 1 != @intFromEnum(mode)) {
        core.panicFmt(
            "attempt to switch from panic mode '{s}' directly to '{s}'",
            .{ @tagName(globals.panic_mode), @tagName(mode) },
            null,
        );
    }

    globals.panic_mode = mode;
}

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
        kernel.arch.interrupts.disableInterrupts();

        switch (globals.panic_mode) {
            .no_op => {
                @branchHint(.cold);
            },
        }

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

const globals = struct {
    var panic_mode: PanicMode = .no_op;
};
const std = @import("std");
const core = @import("core");
const kernel = @import("kernel.zig");

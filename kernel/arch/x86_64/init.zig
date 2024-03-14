// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x86_64 = @import("x86_64.zig");

var early_output_serial_port: ?x86_64.SerialPort = null;

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() callconv(core.inline_in_non_debug_calling_convention) void {
    early_output_serial_port = x86_64.SerialPort.init(.COM1, .Baud115200);
}

/// Acquire a writer for the early output setup by `setupEarlyOutput`.
pub fn getEarlyOutput() callconv(core.inline_in_non_debug_calling_convention) ?x86_64.SerialPort.Writer {
    return if (early_output_serial_port) |output| output.writer() else null;
}

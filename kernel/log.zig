// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

/// Translation of the kernel log level to the std.log level.
pub const std_log_level: std.log.Level = .debug; // TODO: hook this up

/// Handles translating the std.log API to the kernel log API.
pub fn stdLogImpl(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = message_level;
    _ = scope;
    _ = format;
    _ = args;

    // TODO: implement logging
}

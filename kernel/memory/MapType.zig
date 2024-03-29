// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const MapType = @This();

/// Accessible from userspace.
user: bool = false,

/// A global mapping that is not flushed on context switch.
global: bool = false,

/// Writeable.
writeable: bool = false,

/// Executable.
executable: bool = false,

/// Uncached.
no_cache: bool = false,

pub fn equal(a: MapType, b: MapType) bool {
    return a.user == b.user and
        a.global == b.global and
        a.writeable == b.writeable and
        a.executable == b.executable and
        a.no_cache == b.no_cache;
}

pub fn print(value: MapType, writer: anytype) !void {
    try writer.writeAll("Type{ ");

    const buffer: []const u8 = &[_]u8{
        if (value.user) 'U' else 'K',
        if (value.writeable) 'W' else 'R',
        if (value.executable) 'X' else '-',
        if (value.global) 'G' else '-',
        if (value.no_cache) 'C' else '-',
    };

    try writer.writeAll(buffer);
    try writer.writeAll(" }");
}

pub inline fn format(
    region: MapType,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return print(region, writer);
}

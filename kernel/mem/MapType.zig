// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const MapType = @This();

/// The mode of the mapping.
///
/// If the mode is `.kernel` then the mapping is inaccessible from userspace, and is not flushed on context switch if
/// supported.
///
/// If the mode is `.user` then the mapping is accessible from userspace and is supported is not accessible from
/// kernelspace by default.
mode: kernel.Mode,

/// Writeable.
writeable: bool = false,

/// Executable.
executable: bool = false,

/// Uncached.
no_cache: bool = false,

/// Write combining.
write_combining: bool = false,

pub fn print(value: MapType, writer: std.io.AnyWriter, indent: usize) !void {
    _ = indent;

    const buffer: []const u8 = &[_]u8{
        if (value.mode == .user) 'U' else 'K',
        if (value.writeable) 'W' else 'R',
        if (value.executable) 'X' else '-',
        if (value.no_cache) 'C' else '-',
    };

    try writer.print("Type{{ {s} }}", .{buffer});
}

pub inline fn format(
    region: MapType,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return if (@TypeOf(writer) == std.io.AnyWriter)
        print(region, writer, 0)
    else
        print(region, writer.any(), 0);
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

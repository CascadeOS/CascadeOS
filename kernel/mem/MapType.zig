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

/// The protection of the mapping.
protection: Protection,

/// Uncached.
no_cache: bool = false,

/// Write combining.
write_combining: bool = false,

pub const Protection = enum {
    /// Read only.
    read,

    /// Read and write.
    read_write,

    /// Execute only.
    ///
    /// If supported by the archtecture reads are not allowed.
    executable,
};

pub fn print(value: MapType, writer: std.io.AnyWriter, indent: usize) !void {
    _ = indent;

    var buf: std.BoundedArray(u8, 7) = .{};

    buf.appendSliceAssumeCapacity(switch (value.mode) {
        .user => "U_",
        .kernel => "K_",
    });

    buf.appendSliceAssumeCapacity(switch (value.protection) {
        .read => "RO",
        .read_write => "RW",
        .executable => "XO",
    });

    buf.appendSliceAssumeCapacity(if (value.no_cache) "_NC" else "_WB");

    try writer.print("Type{{ {s} }}", .{buf.constSlice()});
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

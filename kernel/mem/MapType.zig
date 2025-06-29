// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const MapType = @This();

/// The context of the mapping.
///
/// If the context is `.kernel` then the mapping is inaccessible from userspace, and is not flushed on context switch if
/// supported.
///
/// If the context is `.user` then the mapping is accessible from userspace and if supported is not accessible from
/// kernelspace by default.
context: kernel.Context.Type,

/// The protection of the mapping.
protection: Protection,

cache: Cache = .write_back,

pub const Protection = enum {
    /// Disallow any access.
    none,

    /// Read only.
    read,

    /// Read and write.
    read_write,

    /// Execute only.
    ///
    /// If supported by the archtecture reads are not allowed.
    executable,
};

pub const Cache = enum {
    write_back,

    write_combining,

    uncached,
};

pub fn print(value: MapType, writer: std.io.AnyWriter, indent: usize) !void {
    _ = indent;

    var buf: std.BoundedArray(u8, 7) = .{};

    buf.appendSliceAssumeCapacity(switch (value.context) {
        .user => "U_",
        .kernel => "K_",
    });

    buf.appendSliceAssumeCapacity(switch (value.protection) {
        .none => "NO",
        .read => "RO",
        .read_write => "RW",
        .executable => "XO",
    });

    buf.appendSliceAssumeCapacity(switch (value.cache) {
        .write_back => "_WB",
        .write_combining => "_WC",
        .uncached => "_UC",
    });

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

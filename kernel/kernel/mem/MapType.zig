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

pub fn format(
    region: MapType,
    writer: *std.Io.Writer,
) !void {
    try writer.writeAll("Type{ ");

    try writer.writeAll(switch (region.context) {
        .user => "U_",
        .kernel => "K_",
    });

    try writer.writeAll(switch (region.protection) {
        .none => "NO",
        .read => "RO",
        .read_write => "RW",
        .executable => "XO",
    });

    try writer.writeAll(switch (region.cache) {
        .write_back => "_WB",
        .write_combining => "_WC",
        .uncached => "_UC",
    });

    var buf: std.BoundedArray(u8, 7) = .{};

    buf.appendSliceAssumeCapacity(switch (region.context) {
        .user => "U_",
        .kernel => "K_",
    });

    buf.appendSliceAssumeCapacity(switch (region.protection) {
        .none => "NO",
        .read => "RO",
        .read_write => "RW",
        .executable => "XO",
    });

    buf.appendSliceAssumeCapacity(switch (region.cache) {
        .write_back => "_WB",
        .write_combining => "_WC",
        .uncached => "_UC",
    });

    try writer.writeAll(" }");
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

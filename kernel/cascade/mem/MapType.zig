// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const cascade = @import("cascade");
const core = @import("core");

const MapType = @This();

/// The environment type of the mapping.
///
/// If `.kernel` then the mapping is inaccessible from userspace, and is not flushed on context switch if supported.
///
/// If` .user` then the mapping is accessible from userspace and if supported is not accessible from kernelspace by
/// default.
environment_type: cascade.Environment.Type,

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

    try writer.writeAll(switch (region.environment_type) {
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

    try writer.writeAll(" }");
}

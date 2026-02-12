// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>#

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const MapType = @This();

/// The type of the mapping.
///
/// If `.kernel` then the mapping is inaccessible from userspace, and is not flushed on context switch if supported.
///
/// If` .user` then the mapping is accessible from userspace and if supported is not accessible from kernelspace by
/// default.
type: cascade.Context.Type,

/// The protection of the mapping.
protection: Protection,

cache: Cache = .write_back,

// The ordering/values of these fields is important.
pub const Protection = enum(u8) {
    /// Disallow any access.
    none = 0,

    /// Read only.
    read = 1,

    /// Execute only.
    ///
    /// Reads may still be possible if the architecture does not support execute only.
    execute = 2,

    /// Read and write.
    read_write = 3,

    // TODO: is there a way to support write only without it being the same as read_write when combined with mprotect?
};

pub const Cache = enum {
    write_back,

    write_combining,

    uncached,
};

pub fn equal(region: MapType, other: MapType) bool {
    return region.type == other.type and
        region.protection == other.protection and
        region.cache == other.cache;
}

pub fn format(
    region: MapType,
    writer: *std.Io.Writer,
) !void {
    try writer.writeAll("Type{ ");

    try writer.writeAll(switch (region.type) {
        .user => "U_",
        .kernel => "K_",
    });

    try writer.writeAll(switch (region.protection) {
        .none => "NO",
        .read => "RO",
        .execute => "XO",
        .read_write => "RW",
    });

    try writer.writeAll(switch (region.cache) {
        .write_back => "_WB",
        .write_combining => "_WC",
        .uncached => "_UC",
    });

    try writer.writeAll(" }");
}

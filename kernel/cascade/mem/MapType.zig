// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>#

const std = @import("std");

const cascade = @import("cascade");

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

pub const Protection = struct {
    /// Is read access allowed?
    ///
    /// Some architectures may not support disabling read access.
    read: bool = false,

    /// Is write access allowed?
    write: bool = false,

    /// Is execution allowed?
    ///
    /// Some architectures may not support disabling execution.
    execute: bool = false,

    pub const none: Protection = .{};
    pub const all: Protection = .{ .read = true, .write = true, .execute = true };

    pub fn equal(self: Protection, other: Protection) bool {
        return self.read == other.read and
            self.write == other.write and
            self.execute == other.execute;
    }

    /// Returns `true` if `self` exceeds `other`.
    ///
    /// A `protection` exceeds another if it has any permission that the other does not.
    pub fn exceeds(self: Protection, other: Protection) bool {
        if (self.read and !other.read) return true;
        if (self.write and !other.write) return true;
        if (self.execute and !other.execute) return true;
        return false;
    }

    pub fn format(self: Protection, writer: *std.Io.Writer) !void {
        if (self.read) try writer.writeByte('R');
        if (self.write) try writer.writeByte('W');
        if (self.execute) try writer.writeByte('X');
        // try writer.writeByte(if (self.read) 'R' else '_');
        // try writer.writeByte(if (self.write) 'W' else '_');
        // try writer.writeByte(if (self.execute) 'X' else '_');
    }
};

pub const Cache = enum {
    write_back,

    write_combining,

    uncached,
};

pub fn equal(map_type: MapType, other: MapType) bool {
    return map_type.type == other.type and
        map_type.protection.equal(other.protection) and
        map_type.cache == other.cache;
}

pub fn format(
    map_type: MapType,
    writer: *std.Io.Writer,
) !void {
    try writer.writeAll("MapType{ ");

    try writer.writeByte(switch (map_type.type) {
        .user => 'U',
        .kernel => 'K',
    });

    try map_type.protection.format(writer);

    try writer.writeAll(switch (map_type.cache) {
        .write_back => "_WB",
        .write_combining => "_WC",
        .uncached => "_UC",
    });

    try writer.writeAll(" }");
}

// SPDX-License-Identifier: LicenseRef-NON-AI-CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const LibraryDescription = @import("../build/LibraryDescription.zig");

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "bitjuggle", .dependencies = &.{"core"} },
    .{ .name = "core" },
    .{ .name = "fs", .dependencies = &.{ "core", "uuid" } },
    .{ .name = "sdf" },
    // TODO: this should be called "cascade" but that confuses ZLS, techatrix has recently made some progress on this but it support zig 0.16 only
    .{ .name = "user_cascade" },
    .{ .name = "uuid", .dependencies = &.{"core"} },
};

// SPDX-License-Identifier: LicenseRef-NON-AI-CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const LibraryDescription = @import("../build/LibraryDescription.zig");

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "bitjuggle", .dependencies = &.{"core"} },
    .{ .name = "core" },
    .{ .name = "elf" },
    .{ .name = "fs", .dependencies = &.{ "core", "uuid" } },
    .{ .name = "limine", .dependencies = &.{ "core", "uuid" } },
    .{ .name = "sdf" },
    .{ .name = "uuid", .dependencies = &.{"core"} },
};

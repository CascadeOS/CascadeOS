// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const LibraryDescription = @import("../build/LibraryDescription.zig");

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "bitjuggle" },
    .{ .name = "containers", .dependencies = &.{ "core", "bitjuggle" } },
    .{ .name = "core" },
    .{ .name = "fs", .dependencies = &.{ "core", "uuid" } },
    .{ .name = "sdf", .dependencies = &.{} },
    .{ .name = "uuid", .dependencies = &.{"core"} },
};

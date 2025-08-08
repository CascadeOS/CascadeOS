// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "bitjuggle", .dependencies = &.{"core"} },
    .{ .name = "core" },
    .{ .name = "fs", .dependencies = &.{ "core", "uuid" } },
    .{ .name = "limine", .dependencies = &.{ "core", "uuid" } },
    .{ .name = "sdf" },
    .{ .name = "uuid", .dependencies = &.{"core"} },
    .{
        .name = "x64",
        .dependencies = &.{ "core", "bitjuggle" },
        .supported_architectures = &.{.x64},
        .need_llvm = true,
    },
};

const LibraryDescription = @import("../build/LibraryDescription.zig");

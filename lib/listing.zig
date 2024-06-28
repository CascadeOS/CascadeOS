// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const LibraryDescription = @import("../build/LibraryDescription.zig");

pub const libraries: []const LibraryDescription = &[_]LibraryDescription{
    .{
        .name = "acpi",
        .dependencies = &.{.{ .name = "core" }},
    },
    .{
        .name = "arm64",
        .dependencies = &.{ .{ .name = "core" }, .{ .name = "bitjuggle" } },
        .supported_targets = &.{.arm64},
    },
    .{ .name = "bitjuggle" },
    .{
        .name = "containers",
        .dependencies = &.{ .{ .name = "core" }, .{ .name = "bitjuggle" } },
    },
    .{ .name = "core" },
    .{
        .name = "fs",
        .dependencies = &.{ .{ .name = "core" }, .{ .name = "uuid" } },
    },
    .{
        .name = "limine",
        .dependencies = &.{.{ .name = "core" }},
    },
    .{ .name = "sdf" },
    .{
        .name = "uuid",
        .dependencies = &.{.{ .name = "core" }},
    },
    .{
        .name = "x64",
        .dependencies = &.{ .{ .name = "core" }, .{ .name = "bitjuggle" } },
        .supported_targets = &.{.x64},
    },
};

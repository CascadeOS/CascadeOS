// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const libraries: []const LibraryDescription = &[_]LibraryDescription{
    .{
        .name = "acpi",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
        },
    },
    .{
        .name = "arm64",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .supported_targets = &.{.arm64},
    },
    .{ .name = "bitjuggle" },
    .{
        .name = "containers",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
    },
    .{ .name = "core" },
    .{
        .name = "fs",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
            .{ .name = "uuid" },
        },
    },
    .{
        .name = "limine",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
        },
    },
    .{ .name = "sdf" },
    .{
        .name = "uuid",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
        },
    },
    .{
        .name = "x64",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .supported_targets = &.{.x64},
    },
};

const LibraryDescription = @import("../build/LibraryDescription.zig");
const LibraryDependency = @import("../build/LibraryDependency.zig");

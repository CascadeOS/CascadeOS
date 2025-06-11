// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const libraries: []const LibraryDescription = &.{
    .{
        .name = "arm",
        .dependencies = &.{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .supported_targets = &.{.arm},
    },
    .{
        .name = "bitjuggle",
        .dependencies = &.{
            .{ .name = "core" },
        },
    },
    .{
        .name = "containers",
        .dependencies = &.{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
    },
    .{ .name = "core" },
    .{
        .name = "fs",
        .dependencies = &.{
            .{ .name = "core" },
            .{ .name = "uuid" },
        },
    },
    .{
        .name = "limine",
        .dependencies = &.{
            .{ .name = "core" },
            .{ .name = "uuid" },
        },
    },
    .{
        .name = "riscv",
        .dependencies = &.{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .supported_targets = &.{.riscv},
    },
    .{ .name = "sdf" },
    .{
        .name = "uuid",
        .dependencies = &.{
            .{ .name = "core" },
        },
    },
    .{
        .name = "x64",
        .dependencies = &.{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .supported_targets = &.{.x64},
        .need_llvm = true,
    },
};

const LibraryDescription = @import("../build/LibraryDescription.zig");
const LibraryDependency = @import("../build/LibraryDependency.zig");

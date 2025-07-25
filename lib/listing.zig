// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const libraries: []const LibraryDescription = &.{
    .{
        .name = "arm",
        .dependencies = &.{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .supported_architectures = &.{.arm},
    },
    .{
        .name = "bitjuggle",
        .dependencies = &.{
            .{ .name = "core" },
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
        .supported_architectures = &.{.riscv},
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
        .supported_architectures = &.{.x64},
        .need_llvm = true,
    },
};

const LibraryDescription = @import("../build/LibraryDescription.zig");
const LibraryDependency = @import("../build/LibraryDependency.zig");

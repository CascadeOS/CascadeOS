// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const libraries: []const LibraryDescription = &[_]LibraryDescription{
    .{
        .name = "arm",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .supported_targets = &.{.arm},
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
            .{ .name = "uuid" },
        },
    },
    .{
        .name = "riscv",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .supported_targets = &.{.riscv},
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
        .need_llvm = true,
    },
};

const LibraryDescription = @import("../build/LibraryDescription.zig");
const LibraryDependency = @import("../build/LibraryDependency.zig");

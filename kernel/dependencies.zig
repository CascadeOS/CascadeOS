// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const LibraryDependency = @import("../build/LibraryDependency.zig");

pub const core_dependencies: []const LibraryDependency = &.{
    .{ .name = "acpi" },
    .{ .name = "containers" },
    .{ .name = "core" },
    .{ .name = "limine" },
    .{ .name = "sdf" },
};

pub const arm64_dependencies: []const LibraryDependency = &.{
    .{ .name = "arm64", .import_name = "lib_arm64" },
};

pub const riscv_dependencies: []const LibraryDependency = &.{
    .{ .name = "riscv", .import_name = "lib_riscv" },
};

pub const x64_dependencies: []const LibraryDependency = &.{
    .{ .name = "x64", .import_name = "lib_x64" },
};

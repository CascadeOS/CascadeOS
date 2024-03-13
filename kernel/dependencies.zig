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

pub const x86_64_dependencies: []const LibraryDependency = &.{
    .{ .name = "x86_64", .import_name = "lib_x86_64" },
};

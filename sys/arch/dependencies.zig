// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const dependencies: []const LibraryDependency = &[_]LibraryDependency{
    .{ .name = "acpi" },
    .{ .name = "core" },
};

pub const arm64_dependencies: []const LibraryDependency = &[_]LibraryDependency{
    .{ .name = "arm64", .import_name = "lib_arm64" },
};

pub const x64_dependencies: []const LibraryDependency = &[_]LibraryDependency{
    .{ .name = "x64", .import_name = "lib_x64" },
};

const LibraryDependency = @import("../../build/LibraryDependency.zig");

// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const dependencies: []const LibraryDependency = &[_]LibraryDependency{
    .{ .name = "acpi" },
    .{ .name = "containers" },
    .{ .name = "core" },
    .{ .name = "sdf" },
};

const LibraryDependency = @import("../../build/LibraryDependency.zig");

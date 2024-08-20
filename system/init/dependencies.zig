// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const LibraryDependency = @import("../../build/LibraryDependency.zig");

pub const dependencies: []const LibraryDependency = &.{
    .{ .name = "acpi" },
    .{ .name = "containers" },
    .{ .name = "core" },
};

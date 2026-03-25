// SPDX-License-Identifier: LicenseRef-NON-AI-CC0-1.0
// SPDX-FileCopyrightText: CascadeOS Contributors

const LibraryDescription = @import("../build/LibraryDescription.zig");

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "bitjuggle", .dependencies = &.{"core"} },
    .{ .name = "cascade", .is_cascade_only = true },
    .{ .name = "core" },
    .{ .name = "fs", .dependencies = &.{ "core", "uuid" } },
    .{ .name = "uuid", .dependencies = &.{"core"} },
};

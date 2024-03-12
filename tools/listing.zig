// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const ToolDescription = @import("../build/ToolDescription.zig");

pub const tools: []const ToolDescription = &[_]ToolDescription{
    .{
        .name = "image_builder",
        .dependencies = &.{ .{ .name = "core" }, .{ .name = "fs" }, .{ .name = "uuid" } },
    },
    .{
        .name = "sdf_builder",
        .dependencies = &.{ .{ .name = "core" }, .{ .name = "sdf" } },
        .custom_configuration = @import("sdf_builder/custom_configuration.zig").customConfiguration,
    },
};

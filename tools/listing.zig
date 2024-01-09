// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const ToolDescription = @import("../build/ToolDescription.zig");

pub const tools: []const ToolDescription = &.{
    .{ .name = "image_builder", .dependencies = &.{ "core", "fs", "uuid" } },
};

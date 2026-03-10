// SPDX-License-Identifier: LicenseRef-NON-AI-CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const ToolDescription = @import("../build/ToolDescription.zig");

pub const tools: []const ToolDescription = &.{
    .{ .name = "image_builder", .dependencies = &.{ "core", "fs", "uuid" } },
    .{
        .name = "limine_install",
        .configuration = .{
            .custom = @import("limine_install/custom_configuration.zig").customConfiguration,
        },
    },
};

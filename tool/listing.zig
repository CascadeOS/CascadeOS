// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const tools: []const ToolDescription = &.{
    .{ .name = "image_builder", .dependencies = &.{ "core", "fs", "uuid" } },
    .{ .name = "kernel_log_wrapper", .dependencies = &.{"core"} },
    .{
        .name = "limine_install",
        .configuration = .{
            .custom = @import("limine_install/custom_configuration.zig").customConfiguration,
        },
    },
    .{
        .name = "sdf_builder",
        .dependencies = &.{ "core", "sdf" },
        .configuration = .{
            .custom = @import("sdf_builder/custom_configuration.zig").customConfiguration,
        },
    },
};

const ToolDescription = @import("../build/ToolDescription.zig");

// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const tools: []const ToolDescription = &.{
    .{
        .name = "image_builder",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
            .{ .name = "fs" },
            .{ .name = "uuid" },
        },
    },
    .{
        .name = "log_wrapper",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
        },
        .custom_configuration = @import("log_wrapper/custom_configuration.zig").customConfiguration,
    },
    .{
        .name = "sdf_builder",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
            .{ .name = "sdf" },
        },
        .custom_configuration = @import("sdf_builder/custom_configuration.zig").customConfiguration,
    },
};

const ToolDescription = @import("../build/ToolDescription.zig");
const LibraryDependency = @import("../build/LibraryDependency.zig");

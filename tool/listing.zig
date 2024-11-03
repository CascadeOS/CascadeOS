// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const tools: []const ToolDescription = &[_]ToolDescription{
    .{
        .name = "image_builder",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
            .{ .name = "fs" },
            .{ .name = "uuid" },
        },
    },
    .{
        .name = "kernel_log_wrapper",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
        },
        .configuration = .link_c,
    },
    .{
        .name = "sdf_builder",
        .dependencies = &[_]LibraryDependency{
            .{ .name = "core" },
            .{ .name = "sdf" },
        },
        .configuration = .{
            .custom = @import("sdf_builder/custom_configuration.zig").customConfiguration,
        },
    },
};

const ToolDescription = @import("../build/ToolDescription.zig");
const LibraryDependency = @import("../build/LibraryDependency.zig");

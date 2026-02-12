// SPDX-License-Identifier: LicenseRef-NON-AI-CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const KernelComponent = @import("../build/KernelComponent.zig");

pub const components: []const KernelComponent = &.{
    .{
        .name = "arch",
        .component_dependencies = &.{"kernel"},
        .library_dependencies = &.{
            .{ .name = "cascade", .import_name = "user_cascade" },
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .configuration = @import("arch/custom_configuration.zig").customConfiguration,
    },
    .{
        .name = "boot",
        .component_dependencies = &.{ "arch", "kernel" },
        .library_dependencies = &.{
            .{ .name = "core" },
            .{ .name = "uuid" },
        },
    },
    .{
        .name = "kernel",
        .component_dependencies = &.{ "arch", "boot" },
        .library_dependencies = &.{
            .{ .name = "cascade", .import_name = "user_cascade" },
            .{ .name = "core" },
            .{ .name = "sdf" },
        },
        .configuration = @import("kernel/custom_configuration.zig").customConfiguration,
        .provide_source_file_modules = true,
    },
};

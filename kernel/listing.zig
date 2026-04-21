// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: CascadeOS Contributors

const KernelComponent = @import("../build/KernelComponent.zig");

pub const components: []const KernelComponent = &.{
    .{
        .name = "arch",
        .component_dependencies = &.{"cascade"},
        .library_dependencies = &.{
            .{ .name = "cascade", .import_name = "user_cascade" },
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .configuration = @import("arch/custom_configuration.zig").customConfiguration,
    },
    .{
        .name = "boot",
        .component_dependencies = &.{ "arch", "cascade" },
        .library_dependencies = &.{
            .{ .name = "core" },
            .{ .name = "uuid" },
        },
    },
    .{
        .name = "cascade",
        .component_dependencies = &.{ "arch", "boot" },
        .library_dependencies = &.{
            .{ .name = "cascade", .import_name = "user_cascade" },
            .{ .name = "core" },
        },
        .configuration = @import("cascade/custom_configuration.zig").customConfiguration,
        .provide_source_file_modules = true,
    },
};

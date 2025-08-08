// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const components: []const KernelComponent = &.{
    .{
        .name = "arch",
        .component_dependencies = &.{.{ .name = "kernel" }},
        .library_dependencies = &.{
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .configuration = @import("arch/custom_configuration.zig").customConfiguration,
    },
    .{
        .name = "boot",
        .component_dependencies = &.{
            .{ .name = "arch" },
            .{ .name = "kernel" }, // TODO: remove this once `init` is made its own component
        },
        .library_dependencies = &.{ .{ .name = "core" }, .{ .name = "limine" } },
    },
    .{
        .name = "kernel",
        .component_dependencies = &.{
            .{ .name = "arch" },
            .{ .name = "boot" }, // TODO: remove this once `init` is made its own component
        },
        .library_dependencies = &.{ .{ .name = "core" }, .{ .name = "sdf" } },
        .configuration = @import("kernel/custom_configuration.zig").customConfiguration,
    },
};

const KernelComponent = @import("../build/KernelComponent.zig");

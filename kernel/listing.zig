// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const components: []const KernelComponent = &.{
    .{
        .name = "arch",
        .component_dependencies = &.{"kernel"},
        .library_dependencies = &.{ "core", "bitjuggle" },
        .configuration = @import("arch/custom_configuration.zig").customConfiguration,
    },
    .{
        .name = "boot",
        .component_dependencies = &.{
            "arch",
            "kernel", // TODO: remove this once `init` is made its own component
        },
        .library_dependencies = &.{ "core", "limine" },
    },
    .{
        .name = "kernel",
        .component_dependencies = &.{
            "arch",
            "boot", // TODO: remove this once `init` is made its own component
        },
        .library_dependencies = &.{ "core", "sdf" },
        .configuration = @import("kernel/custom_configuration.zig").customConfiguration,
    },
};

const KernelComponent = @import("../build/KernelComponent.zig");

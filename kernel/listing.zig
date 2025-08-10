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
        .component_dependencies = &.{"init"},
        .library_dependencies = &.{ "core", "limine" },
    },
    .{
        .name = "init",
        .component_dependencies = &.{ "arch", "boot", "kernel" },
        .library_dependencies = &.{"core"},
        .configuration = @import("init/custom_configuration.zig").customConfiguration,
    },
    .{
        .name = "kernel",
        .component_dependencies = &.{ "arch", "init" },
        .library_dependencies = &.{ "core", "sdf" },
        .configuration = @import("kernel/custom_configuration.zig").customConfiguration,
    },
};

const KernelComponent = @import("../build/KernelComponent.zig");

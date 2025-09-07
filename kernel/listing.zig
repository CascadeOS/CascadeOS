// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const KernelComponent = @import("../build/KernelComponent.zig");

pub const components: []const KernelComponent = &.{
    .{
        .name = "arch",
        .component_dependencies = &.{"cascade"},
        .library_dependencies = &.{ "core", "bitjuggle" },
        .configuration = @import("arch/custom_configuration.zig").customConfiguration,
    },
    .{
        .name = "boot",
        .component_dependencies = &.{"init"},
        .library_dependencies = &.{ "core", "limine" },
    },
    .{
        .name = "cascade",
        .component_dependencies = &.{ "arch", "init" },
        .library_dependencies = &.{ "core", "sdf" },
        .configuration = @import("cascade/custom_configuration.zig").customConfiguration,
    },
    .{
        .name = "init",
        .component_dependencies = &.{ "arch", "boot", "cascade" },
        .library_dependencies = &.{"core"},
        .configuration = @import("init/custom_configuration.zig").customConfiguration,
    },
};

// SPDX-License-Identifier: LicenseRef-NON-AI-CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const KernelComponent = @import("../build/KernelComponent.zig");

pub const components: []const KernelComponent = &.{
    .{
        .name = "arch",
        .component_dependencies = &.{"kernel"},
        .library_dependencies = &.{ "core", "bitjuggle" },
        .configuration = @import("arch/custom_configuration.zig").customConfiguration,
    },
    .{
        .name = "boot",
        .component_dependencies = &.{ "arch", "kernel" },
        .library_dependencies = &.{ "core", "uuid" },
    },
    .{
        .name = "kernel",
        .component_dependencies = &.{ "arch", "boot" },
        .library_dependencies = &.{ "core", "sdf" },
        .configuration = @import("kernel/custom_configuration.zig").customConfiguration,
        .provide_source_file_modules = true,
    },
};

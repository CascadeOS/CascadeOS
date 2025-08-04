// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const components: []const KernelComponent = &.{ .{
    .name = "kernel",
    .component_dependencies = &.{
        .{ .name = "arch" },
    },
    .library_dependencies = &.{
        .{ .name = "core" },
        .{ .name = "limine" },
        .{ .name = "sdf" },
    },
    .configuration = @import("kernel/custom_configuration.zig").customConfiguration,
}, .{
    .name = "arch",
    .component_dependencies = &.{
        .{ .name = "kernel" },
    },
    .library_dependencies = &.{
        .{ .name = "core" },
        .{
            .name = "arm",
            .condition = .{
                .architecture = &.{.arm},
            },
        },
        .{
            .name = "riscv",
            .condition = .{
                .architecture = &.{.riscv},
            },
        },
        .{
            .name = "x64",
            .condition = .{
                .architecture = &.{.x64},
            },
        },
    },
    .configuration = @import("arch/custom_configuration.zig").customConfiguration,
} };

const KernelComponent = @import("../build/KernelComponent.zig");

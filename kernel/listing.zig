// SPDX-License-Identifier: CC0-1.0
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const components: []const KernelComponent = &.{
    .{
        .name = "kernel",
        .component_dependencies = &.{},
        .library_dependencies = &.{
            .{ .name = "core" },
            .{ .name = "limine" },
            .{ .name = "sdf" },
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
        .configuration = @import("kernel/custom_configuration.zig").customConfiguration,
    },
};

const KernelComponent = @import("../build/KernelComponent.zig");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: Copyright (c) 2025 Zig OSDev Community (https://github.com/zig-osdev/zig-limine-install)

pub fn customConfiguration(
    b: *std.Build,
    tool_description: ToolDescription,
    module: *std.Build.Module,
) void {
    _ = tool_description;

    const limine = b.dependency("limine", .{});

    module.link_libc = true;
    module.addIncludePath(limine.path("."));
    module.addCSourceFile(.{
        .file = limine.path("limine.c"),
        .flags = &.{
            "-std=c99",
            "-Dmain=limine_main",
            "-fno-sanitize=undefined",
        },
    });
}

const std = @import("std");
const builtin = @import("builtin");

const ToolDescription = @import("../../build/ToolDescription.zig");

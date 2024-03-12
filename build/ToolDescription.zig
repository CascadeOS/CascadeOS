// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const LibraryDependency = @import("LibraryDependency.zig");

const ToolDescription = @This();

/// The name of the tool:
///   - used for the path to the root file path `tools/{name}/{name}.zig`
///   - used in any build steps created for the tool
name: []const u8,

/// The tools's dependencies.
dependencies: []const LibraryDependency = &.{},

/// Allows for custom configuration of the tool.
custom_configuration: ?*const fn (
    b: *std.Build,
    tool_description: ToolDescription,
    exe: *std.Build.Step.Compile,
) void = null,

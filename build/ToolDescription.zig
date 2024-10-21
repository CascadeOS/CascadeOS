// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const ToolDescription = @This();

/// The name of the tool:
///   - used for the path to the root file `tools/{name}/{name}.zig`
///   - used in any build steps created for the tool
name: []const u8,

/// The tools's dependencies.
dependencies: []const LibraryDependency = &.{},

/// Allows for custom configuration of the tool.
configuration: Configuration = .simple,

pub const Configuration = union(enum) {
    simple,

    /// The same as `simple` but links libc.
    link_c,

    custom: CustomFn,

    pub const CustomFn = *const fn (
        b: *std.Build,
        tool_description: ToolDescription,
        exe: *std.Build.Step.Compile,
    ) void;
};

const std = @import("std");

const LibraryDependency = @import("LibraryDependency.zig");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const LibraryDependency = @import("LibraryDependency.zig");

const ApplicationDescription = @This();

/// The name of the application:
///   - used for the path to the root file `apps/{name}/{name}.zig`
///   - used in any build steps created for the application
name: []const u8,

/// The applications dependencies.
dependencies: []const LibraryDependency = &.{},

/// Allows for custom configuration of the application.
custom_configuration: ?*const fn (
    b: *std.Build,
    application_description: ApplicationDescription,
    exe: *std.Build.Step.Compile,
) void = null,

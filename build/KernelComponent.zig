// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const KernelComponent = @This();

/// The name of the kernel component:
///   - used as the name of the module provided `@import("{name}");`
///   - used to build the root file path `kernel/{name}/{name}.zig`
name: []const u8,

/// The other kernel components that this component can access via `@import`.
component_dependencies: []const []const u8 = &.{},

/// The libraries that this component can access via `@import`.
library_dependencies: []const []const u8 = &.{},

configuration: ?*const fn (
    b: *std.Build,
    architecture: CascadeTarget.Architecture,
    module: *std.Build.Module,
    options: Options,
    is_check: bool,
) anyerror!void = null,

const std = @import("std");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Options = @import("Options.zig");

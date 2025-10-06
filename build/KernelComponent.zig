// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const Options = @import("Options.zig");

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

/// Provide the source file modules used for printing source code in stacktraces to this component.
///
/// This is intended to be used by the `cascade` component.
provide_source_file_modules: bool = false,

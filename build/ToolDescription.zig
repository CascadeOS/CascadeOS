// SPDX-License-Identifier: MIT

const std = @import("std");

/// The name of the tool:
///   - used for the path to the root file path `tools/{name}/{name}.zig`
///   - used in any build steps created for the tool
name: []const u8,

/// The tools's dependencies.
///
/// Specified as an array of the names of the dependant libraries.
dependencies: []const []const u8 = &.{},

// SPDX-License-Identifier: MIT

const std = @import("std");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

/// The name of the library:
///   - used as the name of the module provided `@import("{name}");`
///   - used to build the root file path `libraries/{name}/{name}.zig`
///   - used in any build steps created for the library
name: []const u8,

dependencies: []const []const u8 = &.{},

/// The list of architectures supported by the library.
/// `null` means architecture-independent.
supported_architectures: ?[]const CascadeTarget = null,

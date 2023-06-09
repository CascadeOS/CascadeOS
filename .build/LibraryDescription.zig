// SPDX-License-Identifier: MIT

const std = @import("std");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

/// The name of the library:
///   - used as the name of the module provided `@import("{name}");`
///   - used to build the root file path `libraries/{name}/{name}.zig`
///   - used in any build steps created for the library
name: []const u8,

/// The library's dependencies.
/// Specified as an array of the names of the dependant libraries.
dependencies: []const []const u8 = &.{},

/// The targets supported by the library.
/// `null` means target-independent.
supported_targets: ?[]const CascadeTarget = null,

// TODO: Should this list the non-cascade operating systems supported?
/// Whether the library can only be used or tested within Cascade.
is_cascade_only: bool = false,

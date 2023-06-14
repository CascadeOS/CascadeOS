// SPDX-License-Identifier: MIT

const std = @import("std");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

/// The name of the library:
///   - used as the name of the module provided `@import("{name}");`
///   - used to build the root file path `libraries/{name}/{name}.zig`
///   - used in any build steps created for the library
name: []const u8,

dependencies: []const []const u8 = &.{},

/// The list of targets supported by the library.
/// `null` means target-independent.
supported_targets: ?[]const CascadeTarget = null,

// TODO: Should this list the non-cascade operating systems supported?
/// If this is `true` then this library cannot be used or tested outside of Cascade.
cascade_only: bool = false,

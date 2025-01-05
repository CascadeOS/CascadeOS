// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// The name of the library:
///   - used as the name of the module provided `@import("{name}");` (unless overridden with `LibraryDependency.import_name`)
///   - used to build the root file path `libraries/{name}/{name}.zig`
///   - used in any build steps created for the library
name: []const u8,

/// The library's dependencies.
dependencies: []const LibraryDependency = &.{},

/// The targets supported by the library.
///
/// `null` means target-independent.
supported_targets: ?[]const CascadeTarget = null,

/// Whether the library can only be used or tested within Cascade.
is_cascade_only: bool = false,

/// The file name of the libraries root file.
///
/// If `null`, defaults to "name.zig".
root_file_name: ?[]const u8 = null,

const std = @import("std");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;
const LibraryDependency = @import("LibraryDependency.zig");

// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

/// The name of the application:
///   - used as the name of the executable
///   - used for the path to the root file `user/{name}/{name}.zig`
///   - used in any build steps created for the applications
name: []const u8,

/// The names of the libraries this application depends on.
dependencies: []const []const u8 = &.{},

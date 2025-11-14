// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const CascadeTarget = @import("CascadeTarget.zig").CascadeTarget;

/// The name of the application:
///   - used as the name of the executable
///   - used for the path to the root file `user/{name}/{name}.zig`
///   - used in any build steps created for the applications
name: []const u8,

/// The names of the libraries this application depends on.
dependencies: []const []const u8 = &.{},

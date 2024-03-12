// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

/// Name of the library.
name: []const u8,

/// String used to import the library.
///
/// If `null`, the library will be imported as `@import("{name}");`.
import_name: ?[]const u8 = null,

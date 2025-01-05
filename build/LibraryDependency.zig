// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// Name of the library.
name: []const u8,

/// String used to import the library.
///
/// If `null`, the library will be imported as `@import("{name}");`.
import_name: ?[]const u8 = null,

const std = @import("std");

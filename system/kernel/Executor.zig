// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.

const Executor = @This();

id: Id,

arch: @import("arch").PerExecutor,

/// A unique identifier for the executor.
pub const Id = enum(u32) {
    bootstrap = 0,

    none = std.math.maxInt(u32),

    _,
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

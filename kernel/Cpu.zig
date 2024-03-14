// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

id: Id,

pub const Id = enum(u64) {
    bootstrap = 0,

    none = std.math.maxInt(u64),

    _,
};

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.

id: Id,

arch: @import("arch").PerExecutor = .{},

/// A unique identifier for the executor.
///
/// `Value - 1` is used as an index into the `kernel.system.executor` array.
pub const Id = enum(u32) {
    none = 0,

    _,
};

const Executor = @This();

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

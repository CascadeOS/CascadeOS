// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.

const Executor = @This();

id: Id,

arch: @import("arch").PerExecutor = .{},

/// A unique identifier for the executor.
///
/// `Value - 1` is used as an index into the `kernel.system.executor` array.
pub const Id = enum(u32) {
    none = 0,

    bootstrap = 1,

    _,
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

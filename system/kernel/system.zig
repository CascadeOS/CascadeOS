// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Array of all executors.
///
/// Initialized during init and never modified again.
pub var executors: std.BoundedArray(kernel.Executor, kernel.config.limits.max_executors) = .{};

/// Returns the executor with the given id.
///
/// It is the caller's responsibility to ensure that the id is valid.
pub inline fn getExecutor(id: kernel.Executor.Id) *kernel.Executor {
    std.debug.assert(id != .none);
    return &executors.slice()[@intFromEnum(id) - 1];
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

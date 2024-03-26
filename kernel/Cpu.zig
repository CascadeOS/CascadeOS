// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

id: Id,

/// The stack used for idle.
///
/// Also used during the move from the bootloader provided stack until we start scheduling.
idle_stack: kernel.Stack,

arch: kernel.arch.ArchCpu,

pub const Id = enum(u64) {
    none = std.math.maxInt(u64),

    _,
};

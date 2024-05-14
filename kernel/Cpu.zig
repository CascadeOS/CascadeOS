// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

id: Id,

/// Tracks the number of times we have disabled interrupts.
///
/// This allows support for nested disables.
interrupt_disable_count: u32,

arch: kernel.arch.ArchCpu,

pub const Id = enum(u32) {
    bootstrap = 0,
    none = std.math.maxInt(u32),

    _,
};

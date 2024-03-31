// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a single execution resource.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const Cpu = @This();

id: Id,

/// Tracks the number of times we have disabled interrupts.
///
/// This allows support for nested disables.
interrupt_disable_count: u32,

/// Tracks the number of times we have disabled preemption.
///
/// This allows support for nested disables.
preemption_disable_count: u32,

/// The stack used for idle.
///
/// Also used during the move from the bootloader provided stack until we start scheduling.
idle_stack: kernel.Stack,

arch: kernel.arch.ArchCpu,

pub const Id = enum(u32) {
    none = std.math.maxInt(u32),

    _,
};

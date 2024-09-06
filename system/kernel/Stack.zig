// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a kernel stack.

const Stack = @This();

/// The entire virtual range including the guard page.
range: core.VirtualRange,

/// The usable range excluding the guard page.
usable_range: core.VirtualRange,

/// The current stack pointer.
stack_pointer: core.VirtualAddress,

/// Creates a stack from a range.
///
/// Requirements:
/// - `range` must be aligned to 16 bytes.
/// - `range` must fully contain `usable_range`.
pub fn fromRange(range: core.VirtualRange, usable_range: core.VirtualRange) Stack {
    std.debug.assert(range.containsRange(usable_range));
    std.debug.assert(range.address.isAligned(.from(16, .byte)));

    return .{
        .range = range,
        .usable_range = usable_range,
        .stack_pointer = usable_range.endBound(),
    };
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

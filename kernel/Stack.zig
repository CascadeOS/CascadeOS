// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

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

/// Pushes a value onto the stack.
pub fn push(stack: *Stack, comptime T: type, value: T) error{StackOverflow}!void {
    const new_stack_pointer: core.VirtualAddress = stack.stack_pointer.moveBackward(core.Size.of(T));
    if (new_stack_pointer.lessThan(stack.usable_range.address)) return error.StackOverflow;

    const ptr: *T = new_stack_pointer.toPtr(*T);
    ptr.* = value;

    stack.stack_pointer = new_stack_pointer;
}

const stack_size_including_guard_page = kernel.config.kernel_stack_size.add(kernel.arch.paging.standard_page_size);

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

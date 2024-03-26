// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a kernel stack.

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const Stack = @This();

pub const usable_stack_size = kernel.arch.paging.standard_page_size.multiplyScalar(16);

/// The size of the stack including the guard page.
///
/// Only one guard page is used and it is placed at the bottom of the stack to catch overflows.
/// The guard page for the next stack in memory is immediately after our stack top so acts as our guard page to catch
/// underflows.
const stack_size_with_guard_page = usable_stack_size.add(kernel.arch.paging.standard_page_size);
/// The entire virtual range including the guard page.
range: core.VirtualRange,

/// The usable range excluding the guard page.
usable_range: core.VirtualRange,

/// The current stack pointer.
stack_pointer: core.VirtualAddress,

pub fn fromRange(range: core.VirtualRange, usable_range: core.VirtualRange) Stack {
    core.debugAssert(range.containsRange(usable_range));

    return Stack{
        .range = range,
        .usable_range = usable_range,
        .stack_pointer = usable_range.end(),
    };
}

/// Pushes a value onto the stack.
pub fn push(stack: *Stack, value: anytype) error{StackOverflow}!void {
    const T = @TypeOf(value);

    const new_stack_pointer: core.VirtualAddress = stack.stack_pointer.moveBackward(core.Size.of(T));
    if (new_stack_pointer.lessThan(stack.usable_range.address)) return error.StackOverflow;

    stack.stack_pointer = new_stack_pointer;

    const ptr: *T = new_stack_pointer.toPtr(*T);
    ptr.* = value;
}

/// Aligns the stack pointer to the given alignment.
pub fn alignPointer(stack: *Stack, alignment: core.Size) !void {
    const new_stack_pointer: core.VirtualAddress = stack.stack_pointer.alignBackward(alignment);

    if (new_stack_pointer.lessThan(stack.usable_range.address)) return error.StackOverflow;

    stack.stack_pointer = new_stack_pointer;
}

const RETURN_ADDRESS_ALIGNMENT = core.Size.from(16, .byte);

/// Pushes a return address to the stack.
pub fn pushReturnAddress(stack: *Stack, return_address: core.VirtualAddress) error{StackOverflow}!void {
    const old_stack_pointer = stack.stack_pointer;

    try stack.alignPointer(RETURN_ADDRESS_ALIGNMENT); // TODO: Is this correct on non-x86?
    errdefer stack.stack_pointer = old_stack_pointer;

    try stack.push(return_address.value);
}

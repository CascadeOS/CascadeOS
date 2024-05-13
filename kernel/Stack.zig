// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a kernel stack.

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

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
    core.debugAssert(range.containsRange(usable_range));
    core.debugAssert(range.address.isAligned(core.Size.from(16, .byte)));

    return Stack{
        .range = range,
        .usable_range = usable_range,
        .stack_pointer = usable_range.endBound(),
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

    try stack.alignPointer(RETURN_ADDRESS_ALIGNMENT); // TODO: Is this correct on non-x64?
    errdefer stack.stack_pointer = old_stack_pointer;

    try stack.push(return_address.value);
}

/// Pushes a return address to the stack without changing the stack pointer.
///
/// Returns the stack pointer with the return address pushed.
pub fn pushReturnAddressWithoutChangingPointer(
    stack: *Stack,
    return_address: core.VirtualAddress,
) error{StackOverflow}!core.VirtualAddress {
    const old_stack_pointer = stack.stack_pointer;
    defer stack.stack_pointer = old_stack_pointer;

    try stack.alignPointer(RETURN_ADDRESS_ALIGNMENT); // TODO: Is this correct on non-x64?
    try stack.push(return_address.value);

    return stack.stack_pointer;
}

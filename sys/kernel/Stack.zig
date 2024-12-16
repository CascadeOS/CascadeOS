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

/// Pushes a return address to the stack.
pub fn pushReturnAddress(stack: *Stack, return_address: core.VirtualAddress) error{StackOverflow}!void {
    const old_stack_pointer = stack.stack_pointer;

    const RETURN_ADDRESS_ALIGNMENT = core.Size.from(16, .byte); // TODO: Is this correct on non-x64?

    try stack.alignPointer(RETURN_ADDRESS_ALIGNMENT);
    errdefer stack.stack_pointer = old_stack_pointer;

    try stack.push(return_address.value);
}

pub fn createStack() !Stack {
    const stack_range = try globals.stack_arena.allocate(
        stack_size_including_guard_page.value,
        .instant_fit,
    );

    const stack = fromRange(
        .{ .address = .fromInt(stack_range.base), .size = stack_size_including_guard_page },
        .{ .address = .fromInt(stack_range.base), .size = kernel.config.kernel_stack_size },
    );

    try kernel.mem.mapRange(
        &kernel.mem.globals.core_page_table,
        stack.usable_range,
        .{ .writeable = true, .global = true },
    );

    return stack;
}

pub fn destroyStack(stack: Stack) void {
    try kernel.mem.unmapRange(
        &kernel.mem.globals.core_page_table,
        stack.usable_range,
        true,
    );

    globals.stack_arena.deallocate(.{
        .base = stack.range.address.value,
        .len = stack.range.size.value,
    });
}

const stack_size_including_guard_page = kernel.config.kernel_stack_size.add(arch.paging.standard_page_size);

pub const globals = struct {
    pub var stack_arena: kernel.mem.ResourceArena = undefined;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");

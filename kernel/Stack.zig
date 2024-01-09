// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Represents a kernel stack.

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const Stack = @This();

pub const usable_stack_size = kernel.arch.paging.standard_page_size.multiply(16);

/// The size of the stack including the guard page.
///
/// Only one guard page is used and it is placed at the bottom of the stack to catch overflows.
/// The guard page for the next stack in memory is immediately after our stack top so acts as our guard page to catch underflows.
const stack_size_with_guard_page = usable_stack_size.add(kernel.arch.paging.standard_page_size);

var stacks_range_allocator: kernel.heap.RangeAllocator = undefined;
var stacks_range_allocator_lock: kernel.SpinLock = .{};

/// The entire virtual range including the guard page.
range: kernel.VirtualRange,

/// The usable range excluding the guard page.
usable_range: kernel.VirtualRange,

/// The current stack pointer.
stack_pointer: kernel.VirtualAddress,

pub fn fromRangeNoGuard(range: kernel.VirtualRange) Stack {
    return Stack{
        .range = range,
        .usable_range = range,
        .stack_pointer = range.end(),
    };
}

pub fn fromRangeWithGuard(range: kernel.VirtualRange, usable_range: kernel.VirtualRange) Stack {
    core.debugAssert(range.containsRange(usable_range));

    return Stack{
        .range = range,
        .usable_range = usable_range,
        .stack_pointer = usable_range.end(),
    };
}

pub fn create(push_null_return_value: bool) !Stack {
    const virtual_range = blk: {
        const held = stacks_range_allocator_lock.lock();
        defer held.unlock();

        break :blk try stacks_range_allocator.allocateRange(stack_size_with_guard_page);
    };
    errdefer {
        const held = stacks_range_allocator_lock.lock();
        defer held.unlock();

        stacks_range_allocator.deallocateRange(virtual_range) catch {
            core.panic("deallocateRange failed"); // FIXME
        };
    }

    // Don't map the guard page.
    var usable_range = virtual_range.moveForward(kernel.arch.paging.standard_page_size);
    usable_range.size.subtractInPlace(kernel.arch.paging.standard_page_size);

    try kernel.memory.virtual.mapRange(
        kernel.kernel_process.page_table,
        usable_range,
        .{ .global = true, .writeable = true },
    );
    errdefer kernel.memory.virtual.unmap(kernel.kernel_process.page_table, usable_range);

    var stack = fromRangeWithGuard(virtual_range, usable_range);

    if (push_null_return_value) {
        try stack.pushReturnAddress(kernel.VirtualAddress.zero);
    }

    return stack;
}

/// Destroys a stack.
///
/// **REQUIREMENTS**:
/// - `stack` must have been created with `create`.
pub fn destroy(stack: Stack) void {
    kernel.memory.virtual.unmap(kernel.root_page_table, stack.usable_range);

    // TODO: Cache needs to be flushed on this core and others.
}

/// Pushes a value onto the stack.
pub fn push(stack: *Stack, value: anytype) error{StackOverflow}!void {
    const T = @TypeOf(value);

    const new_stack_pointer: kernel.VirtualAddress = stack.stack_pointer.moveBackward(core.Size.of(T));
    if (new_stack_pointer.lessThan(stack.usable_range.address)) return error.StackOverflow;

    stack.stack_pointer = new_stack_pointer;

    const ptr: *T = new_stack_pointer.toPtr(*T);
    ptr.* = value;
}

/// Aligns the stack pointer to the given alignment.
pub fn alignPointer(stack: *Stack, alignment: core.Size) !void {
    const new_stack_pointer: kernel.VirtualAddress = stack.stack_pointer.alignBackward(alignment);

    if (new_stack_pointer.lessThan(stack.usable_range.address)) return error.StackOverflow;

    stack.stack_pointer = new_stack_pointer;
}

const RETURN_ADDRESS_ALIGNMENT = core.Size.from(16, .byte);

/// Pushes a return address to the stack.
pub fn pushReturnAddress(stack: *Stack, return_address: kernel.VirtualAddress) error{StackOverflow}!void {
    const old_stack_pointer = stack.stack_pointer;

    try stack.alignPointer(RETURN_ADDRESS_ALIGNMENT); // TODO: Is this correct on non-x86?
    errdefer stack.stack_pointer = old_stack_pointer;

    try stack.push(return_address.value);
}

/// Pushes a return address to the stack without changing the stack pointer.
///
/// Returns the stack pointer with the return address pushed.
pub fn pushReturnAddressWithoutChangingPointer(
    stack: *Stack,
    return_address: kernel.VirtualAddress,
) error{StackOverflow}!kernel.VirtualAddress {
    const old_stack_pointer = stack.stack_pointer;
    defer stack.stack_pointer = old_stack_pointer;

    try stack.alignPointer(RETURN_ADDRESS_ALIGNMENT); // TODO: Is this correct on non-x86?
    try stack.push(return_address.value);

    return stack.stack_pointer;
}

pub const init = struct {
    pub fn initStacks(kernel_stacks_range: kernel.VirtualRange) linksection(kernel.info.init_code) !void {
        stacks_range_allocator = try kernel.heap.RangeAllocator.init(kernel_stacks_range);
    }
};

// SPDX-License-Identifier: MIT

//! Represents a kernel stack.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

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

pub fn create() !Stack {
    const virtual_range = blk: {
        const held = stacks_range_allocator_lock.lock();
        defer held.unlock();

        break :blk try stacks_range_allocator.allocateRange(stack_size_with_guard_page);
    };
    errdefer {
        const held = stacks_range_allocator_lock.lock();
        defer held.unlock();

        stacks_range_allocator.deallocateRange(virtual_range) catch {
            // FIXME: we have no way to recover from this
            core.panic("deallocateRange failed");
        };
    }

    // Don't map the guard page.
    var usable_range = virtual_range.moveForward(kernel.arch.paging.standard_page_size);
    usable_range.size.subtractInPlace(kernel.arch.paging.standard_page_size);

    try kernel.vmm.mapRange(
        kernel.vmm.kernel_page_table,
        usable_range,
        .{ .global = true, .writeable = true },
    );

    return fromRangeWithGuard(virtual_range, usable_range);
}

/// Destroys a stack.
///
/// **REQUIREMENTS**:
/// - `stack` must have been created with `create`.
pub fn destroy(stack: Stack) void {
    kernel.vmm.unmap(kernel.root_page_table, stack.usable_range);

    // TODO: Cache needs to be flushed on this core and others.
}

pub const init = struct {
    pub fn initStacks(kernel_stacks_range: kernel.VirtualRange) linksection(kernel.info.init_code) !void {
        stacks_range_allocator = try kernel.heap.RangeAllocator.init(kernel_stacks_range);
    }
};

pub fn push(stack: *Stack, value: anytype) error{StackOverflow}!void {
    const T = @TypeOf(value);

    const new_stack_pointer: kernel.VirtualAddress = stack.stack_pointer.moveBackward(core.Size.of(T));
    if (new_stack_pointer.lessThan(stack.usable_range.address)) return error.StackOverflow;

    stack.stack_pointer = new_stack_pointer;

    const ptr: *T = new_stack_pointer.toPtr(*T);
    ptr.* = value;
}

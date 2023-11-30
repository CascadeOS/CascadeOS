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

stack_pointer: kernel.VirtualAddress,

pub fn fromRange(range: kernel.VirtualRange) Stack {
    return Stack{
        .range = range,
        .stack_pointer = range.end(),
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
    var range_to_map = virtual_range.moveForward(kernel.arch.paging.standard_page_size);
    range_to_map.size.subtractInPlace(kernel.arch.paging.standard_page_size);

    try kernel.vmm.mapRange(
        kernel.vmm.kernel_page_table,
        range_to_map,
        .{ .global = true, .writeable = true },
    );

    return fromRange(virtual_range);
}

/// Destroys a stack.
///
/// **REQUIREMENTS**:
/// - `stack` must have been created with `create`.
pub fn destroy(stack: Stack) void {
    // The guard page was not mapped.
    var range_to_unmap = stack.range.moveForward(kernel.arch.paging.standard_page_size);
    range_to_unmap.size.subtractInPlace(kernel.arch.paging.standard_page_size);

    kernel.vmm.unmap(kernel.root_page_table, range_to_unmap);

    // TODO: Cache needs to be flushed on this core and others.
}

pub const init = struct {
    pub fn initStacks(kernel_stacks_range: kernel.VirtualRange) linksection(kernel.info.init_code) !void {
        stacks_range_allocator = try kernel.heap.RangeAllocator.init(kernel_stacks_range);
    }
};

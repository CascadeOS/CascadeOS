// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const Stack = kernel.Stack;

const log = kernel.log.scoped(.kernel_stacks);

/// The size of the stack including the guard page.
///
/// Only one guard page is used and it is placed at the bottom of the stack to catch overflows.
/// The guard page for the next stack in memory is immediately after our stack top so acts as our guard page to catch underflows.
const stack_size_with_guard_page = kernel.config.kernel_stack_size.add(kernel.arch.paging.standard_page_size);

var stacks_range_allocator: kernel.vmm.RangeAllocator = undefined;
var stacks_range_allocator_lock: kernel.sync.Mutex = .{};

pub fn create() !Stack {
    const virtual_range = blk: {
        const held = stacks_range_allocator_lock.acquire();
        defer held.release();

        break :blk try stacks_range_allocator.allocateRange(stack_size_with_guard_page);
    };
    errdefer {
        const held = stacks_range_allocator_lock.acquire();
        defer held.release();

        stacks_range_allocator.deallocateRange(virtual_range) catch {
            core.panic("deallocateRange failed"); // FIXME
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
    errdefer kernel.vmm.unmapRange(kernel.vmm.kernel_page_table, usable_range);

    var stack = Stack.fromRange(virtual_range, usable_range);

    // push a null return value
    try stack.pushReturnAddress(core.VirtualAddress.zero);

    return stack;
}

/// Destroys a stack.
///
/// **REQUIREMENTS**:
/// - `stack` must have been created with `create`.
pub fn destroy(stack: Stack) void {
    kernel.vmm.unmapRange(kernel.vmm.kernel_page_table, stack.usable_range);

    // TODO: Cache needs to be flushed on this core and others.
}

pub const init = struct {
    pub fn initStackAllocator(kernel_stacks_range: core.VirtualRange) !void {
        stacks_range_allocator = try kernel.vmm.RangeAllocator.init(kernel_stacks_range);
    }
};

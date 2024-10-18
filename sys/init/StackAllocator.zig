// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const StackAllocator = @This();

kernel_stacks_heap_range: core.VirtualRange,

pub fn allocate(self: *StackAllocator) kernel.Stack {
    const full_range: core.VirtualRange = core.VirtualRange.fromAddr(
        self.kernel_stacks_heap_range.address,
        kernel.config.kernel_stack_size.add(arch.paging.standard_page_size), // extra page for guard page
    );

    const usable_range: core.VirtualRange = blk: {
        var range = full_range;
        range.size.subtractInPlace(arch.paging.standard_page_size);
        break :blk range;
    };

    self.kernel_stacks_heap_range.moveForwardInPlace(full_range.size);
    self.kernel_stacks_heap_range.size.subtractInPlace(full_range.size);

    return kernel.Stack.fromRange(full_range, usable_range);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.log.scoped(.init_stack_allocator);
const arch = @import("arch");

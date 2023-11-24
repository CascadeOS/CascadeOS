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

// Initialized by `vmm.init`
pub var stacks_range_allocator: kernel.RangeAllocator = undefined;
var stacks_range_allocator_lock: kernel.sync.SpinLock = .{};

/// The entire virtual range including the guard page.
range: kernel.VirtualRange,

/// The top of the stack.
stack_top: kernel.VirtualAddress,

pub fn fromRange(range: kernel.VirtualRange) Stack {
    return Stack{
        .range = range,
        .stack_top = range.end(),
    };
}

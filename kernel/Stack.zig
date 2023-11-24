// SPDX-License-Identifier: MIT

//! Represents a kernel stack.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const Stack = @This();

/// The entire virtual range including guard pages.
full_range: kernel.VirtualRange,

/// The range of the stack that is actually usable.
valid_range: kernel.VirtualRange,

/// The top of the stack.
stack_top: kernel.VirtualAddress,

pub fn fromRangeNoGuard(range: kernel.VirtualRange) Stack {
    return Stack{
        .full_range = range,
        .valid_range = range,
        .stack_top = range.end(),
    };
}

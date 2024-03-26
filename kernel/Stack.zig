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

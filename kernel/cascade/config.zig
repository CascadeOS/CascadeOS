// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
pub const interrupt_source_panic_buffer_size = arch.paging.standard_page_size;
const cascade = @import("cascade");
const core = @import("core");
const kernel_options = @import("kernel_options");
pub const cascade_version = kernel_options.cascade_version;

// TODO: clean up this file, use some namespacing

// This must be kept in sync with the linker scripts.
pub const kernel_base_address: core.VirtualAddress = .fromInt(0xffffffff80000000);

/// The size of the usable region of a kernel stack.
pub const kernel_stack_size = arch.paging.standard_page_size.multiplyScalar(16);

pub const maximum_number_of_time_sources = 8;
pub const maximum_number_of_memory_map_entries = 128;
pub const maximum_number_of_executors = 64;

pub const task_name_length = 64;

pub const process_name_length = 64;
// the process name is also used as the name of its address space
pub const address_space_name_length = process_name_length;

pub const resource_arena_name_length = 64;
pub const cache_name_length = 64;

pub const per_executor_interrupt_period = core.Duration.from(5, .millisecond);

pub const user_address_space_range: core.VirtualRange = .{
    // don't allow the zero page to be mapped
    .address = .fromInt(arch.paging.standard_page_size.value),
    .size = arch.paging.lower_half_size.subtract(arch.paging.standard_page_size),
};
comptime {
    // No special handing of the undefined address is required as it does not overlap with the user address space range.
    std.debug.assert(!user_address_space_range.containsAddress(.undefined_address));
}

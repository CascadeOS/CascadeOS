// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// TODO: clean up this file, use some namespacing

// build system provided kernel options
pub const cascade_version = kernel_options.cascade_version;
pub const cascade_arch = @import("cascade_architecture").arch;

// This must be kept in sync with the linker scripts.
pub const kernel_base_address: core.VirtualAddress = .fromInt(0xffffffff80000000);

/// The size of the usable region of a kernel stack.
pub const kernel_stack_size = arch.paging.standard_page_size.multiplyScalar(16);

pub const maximum_number_of_time_sources = 8;

pub const maximum_number_of_executors = 64;

pub const interrupt_source_panic_buffer_size = arch.paging.standard_page_size;

pub const task_name_length = 64;
// the process name is also used as the name of its address space
pub const process_name_length = address_space_name_length;
pub const resource_arena_name_length = 64;
// the address spaces resource arena has the same name as the address space but with `_address_arena` appended
pub const address_space_name_length = resource_arena_name_length - "_address_arena".len;
pub const cache_name_length = 64;

pub const per_executor_interrupt_period = core.Duration.from(5, .millisecond);

pub const user_address_space_range: core.VirtualRange = .{
    // don't allow the zero page to be mapped
    .address = .fromInt(arch.paging.standard_page_size.value),
    .size = arch.paging.lower_half_size.subtract(arch.paging.standard_page_size),
};

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const kernel_options = @import("kernel_options");
const std = @import("std");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

// build system provided kernel options
pub const cascade_version = kernel_options.cascade_version;
pub const force_debug_log = kernel_options.force_debug_log;
pub const forced_debug_log_scopes = kernel_options.forced_debug_log_scopes;

// This must be kept in sync with the linker scripts.
pub const kernel_base_address: core.VirtualAddress = .fromInt(0xffffffff80000000);

/// The size of the usable region of a kernel stack.
pub const kernel_stack_size = arch.paging.standard_page_size.multiplyScalar(16);

pub const maxium_number_of_time_sources = 8;

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");
const arch = @import("arch");

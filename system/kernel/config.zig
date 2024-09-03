// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

// build system provided kernel options
pub const cascade_version = kernel_options.cascade_version;
pub const force_debug_log = kernel_options.force_debug_log;
pub const forced_debug_log_scopes = kernel_options.forced_debug_log_scopes;

// This must be kept in sync with the linker scripts.
pub const kernel_base_address: core.VirtualAddress = .fromInt(0xffffffff80000000);

pub const limits = struct {
    pub const max_executors = 32;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");

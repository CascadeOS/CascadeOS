// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Comptime known configuration values.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub usingnamespace @import("kernel_options");

// This must be kept in sync with the linker scripts.
pub const kernel_base_address = core.VirtualAddress.fromInt(0xffffffff80000000);

/// The size of the usable region of a kernel stack.
pub const kernel_stack_size = kernel.arch.paging.standard_page_size.multiplyScalar(16);

pub const process_name_length = 32;
pub const task_name_length = 32;

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const all_page_sizes = &.{
    ArchPageTable.small_page_size,
    ArchPageTable.medium_page_size,
    ArchPageTable.large_page_size,
};

pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);

/// The largest possible higher half virtual address.
pub const largest_higher_half_virtual_address: core.VirtualAddress = core.VirtualAddress.fromInt(0xffffffffffffffff);

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
const arch = @import("arch");

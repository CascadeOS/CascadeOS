// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const small_page_size = core.Size.from(4, .kib); // TODO: check this
pub const medium_page_size = core.Size.from(2, .mib);
pub const large_page_size = core.Size.from(1, .gib);

pub const all_page_sizes = &.{
    small_page_size,
    medium_page_size,
    large_page_size,
};

pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);

/// The largest possible higher half virtual address.
pub const largest_higher_half_virtual_address: core.VirtualAddress = core.VirtualAddress.fromInt(0xffffffffffffffff);

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arm64 = @import("arm64.zig");
const lib_arm64 = @import("arm64");

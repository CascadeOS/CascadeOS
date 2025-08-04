// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// TODO: most of these values are copied from the x64, so all of them need to be checked

pub const small_page_size = core.Size.from(4, .kib);
pub const medium_page_size = core.Size.from(2, .mib);
pub const large_page_size = core.Size.from(1, .gib);

pub const all_page_sizes = &.{
    small_page_size,
    medium_page_size,
    large_page_size,
};

pub const lower_half_size: core.Size = .from(128, .tib);
pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);

/// The largest possible higher half virtual address.
pub const largest_higher_half_virtual_address: core.VirtualAddress = core.VirtualAddress.fromInt(0xffffffffffffffff);

pub const ArchPageTable = struct {};

pub const init = struct {};

const kernel = @import("kernel");

const core = @import("core");
const lib_riscv = @import("riscv");
const riscv = @import("riscv.zig");
const std = @import("std");

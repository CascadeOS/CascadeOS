// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// TODO: small page size should be 16kib, will need to update the linker script as well
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

pub const PageTable = struct {};

pub const init = struct {};

const kernel = @import("kernel");

const arm = @import("arm.zig");
const core = @import("core");
const lib_arm = @import("arm");
const std = @import("std");

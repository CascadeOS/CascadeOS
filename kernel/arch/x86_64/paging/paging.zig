// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("../x86_64.zig");

pub const small_page_size = core.Size.from(4, .kib);
pub const medium_page_size = core.Size.from(2, .mib);
pub const large_page_size = core.Size.from(1, .gib);

pub const smallest_page_size = small_page_size;
pub const largest_page_size = large_page_size;

// TODO: This is incorrect for 5-level paging
pub const higher_half = kernel.arch.VirtAddr.fromInt(0xffff800000000000);

pub const PageTable = @import("PageTable.zig").PageTable;

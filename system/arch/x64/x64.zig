// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const interrupts = @import("interrupts.zig");
pub const PerExecutor = @import("PerExecutor.zig");

pub const arch_interface = struct {
    pub const PerExecutor = @import("PerExecutor.zig");

    pub const interrupts = @import("interrupts.zig");

    pub const paging = struct {
        pub const standard_page_size = lib_x64.PageTable.small_page_size;
        pub const all_page_sizes = &.{
            lib_x64.PageTable.small_page_size,
            lib_x64.PageTable.medium_page_size,
            lib_x64.PageTable.large_page_size,
        };

        pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);

        /// The largest possible higher half virtual address.
        pub const largest_higher_half_virtual_address: core.VirtualAddress = core.VirtualAddress.fromInt(0xffffffffffffffff);
    };

    pub const init = @import("init.zig");
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const lib_x64 = @import("lib_x64");

comptime {
    if (@import("cascade_target").arch != .x64) {
        @compileError("x64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

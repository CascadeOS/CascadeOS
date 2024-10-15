// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const init = @import("init.zig");

pub const PerExecutor = struct {};

pub const interrupts = struct {
    pub const disableInterruptsAndHalt = lib_arm64.instructions.disableInterruptsAndHalt;
    pub const disableInterrupts = lib_arm64.instructions.disableInterrupts;

    pub const InterruptContext = struct {};
};

pub const paging = struct {
    pub const small_page_size = core.Size.from(4, .kib);
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

    pub const ArchPageTable = struct {};
    pub const page_table_alignment = small_page_size;
    pub const page_table_size = small_page_size;

    pub const init = struct {};
};

pub const spinLoopHint = lib_arm64.instructions.isb;

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const lib_arm64 = @import("lib_arm64");

comptime {
    if (@import("cascade_target").arch != .arm64) {
        @compileError("arm64 implementation has been referenced when building " ++ @tagName(@import("cascade_target").arch));
    }
}

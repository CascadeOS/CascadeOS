// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const instructions = @import("instructions.zig");
pub const setup = @import("setup.zig");
pub const Uart = @import("Uart.zig");

pub const paging = struct {
    pub const smallest_page_size = core.Size.from(4, .kib);

    // TODO: this depends on the "granule" size
    pub const largest_page_size = core.Size.from(1, .gib);

    // TODO: I don't know if this is correct for aaarch64
    pub const higher_half = kernel.arch.VirtAddr.fromInt(0xffff800000000000);

    // TODO: implement paging support for aaarch64
    pub const PageTable = struct {};
};

// Below here are helpful re-exports from the main arch file
const arch = @import("../arch.zig");
pub const PhysAddr = arch.PhysAddr;
pub const VirtAddr = arch.VirtAddr;
pub const PhysRange = arch.PhysRange;
pub const VirtRange = arch.VirtRange;

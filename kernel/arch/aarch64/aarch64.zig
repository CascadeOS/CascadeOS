// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

comptime {
    // make sure the entry points are referenced
    _ = setup;
}

pub const instructions = @import("instructions.zig");
pub const setup = @import("setup.zig");
pub const Uart = @import("Uart.zig");

const addr = @import("addr.zig");
pub const PhysAddr = addr.PhysAddr;
pub const VirtAddr = addr.VirtAddr;

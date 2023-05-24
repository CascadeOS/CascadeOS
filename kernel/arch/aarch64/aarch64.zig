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

pub usingnamespace @import("../arch_helpers.zig").useful_arch_exports;

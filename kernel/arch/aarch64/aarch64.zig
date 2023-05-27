// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub usingnamespace @import("../arch_helpers.zig").useful_arch_exports;

pub const instructions = @import("instructions.zig");
pub const setup = @import("setup.zig");
pub const Uart = @import("Uart.zig");

pub const smallest_page_size = core.Size.from(4, .kib);

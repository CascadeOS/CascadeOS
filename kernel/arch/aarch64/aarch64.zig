// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub const instructions = @import("instructions.zig");
pub const setup = @import("setup.zig");

comptime {
    // make sure the entry points are referenced
    _ = setup;
}

pub const public = struct {
    pub const disableInterruptsAndHalt = instructions.disableInterruptsAndHalt;
};

// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub const instructions = @import("instructions.zig");
pub const serial = @import("serial.zig");
pub const setup = @import("setup.zig");

comptime {
    // make sure the entry points are referenced
    _ = setup;
}

pub const interface = kernel.arch.ArchInterface{
    .earlyLogFn = setup.earlyLogFn,

    .disableInterruptsAndHalt = instructions.disableInterruptsAndHalt,
};

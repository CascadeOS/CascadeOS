// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

const entry = @import("entry.zig");

pub const instructions = @import("instructions.zig");
pub const serial = @import("serial.zig");

comptime {
    // make sure the entry points are referenced
    _ = entry;
}

}

pub const earlyLogFn = entry.earlyLogFn;
pub const public = struct {
    pub const disableInterruptsAndHalt = instructions.disableInterruptsAndHalt;
};

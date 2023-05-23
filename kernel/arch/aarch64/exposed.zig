// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const aarch64 = @import("aarch64.zig");

// Setup
pub const setupEarlyOutput = aarch64.setup.setupEarlyOutput;
pub const earlyOutputRaw = aarch64.setup.earlyOutputRaw;
pub const earlyLogFn = aarch64.setup.earlyLogFn;

pub const disableInterruptsAndHalt = aarch64.instructions.disableInterruptsAndHalt;

// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const x86_64 = @import("x86_64.zig");

// Setup
pub const setupEarlyOutput = x86_64.setup.setupEarlyOutput;
pub const earlyOutputRaw = x86_64.setup.earlyOutputRaw;
pub const earlyLogFn = x86_64.setup.earlyLogFn;

pub const disableInterruptsAndHalt = x86_64.instructions.disableInterruptsAndHalt;

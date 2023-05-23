// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const aarch64 = @import("aarch64.zig");

// Setup
pub const setupEarlyOutput = aarch64.setup.setupEarlyOutput;
pub const getEarlyOutputWriter = aarch64.setup.getEarlyOutputWriter;

pub const disableInterruptsAndHalt = aarch64.instructions.disableInterruptsAndHalt;

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const disableInterruptsAndHalt = lib_arm.instructions.disableInterruptsAndHalt;
pub const enableInterrupts = lib_arm.instructions.enableInterrupts;
pub const areEnabled = lib_arm.instructions.interruptsEnabled;
pub const disableInterrupts = lib_arm.instructions.disableInterrupts;

pub const Interrupt = enum(u8) {
    _,
};
pub const ArchInterruptFrame = InterruptFrame;
pub const InterruptFrame = extern struct {};

pub const init = struct {};

const kernel = @import("kernel");

const arm = @import("arm.zig");
const core = @import("core");
const lib_arm = @import("arm");
const std = @import("std");

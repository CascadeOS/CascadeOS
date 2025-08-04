// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const disableInterruptsAndHalt = lib_riscv.instructions.disableInterruptsAndHalt;
pub const enableInterrupts = lib_riscv.instructions.enableInterrupts;
pub const areEnabled = lib_riscv.instructions.interruptsEnabled;
pub const disableInterrupts = lib_riscv.instructions.disableInterrupts;

pub const Interrupt = enum(u8) {
    _,
};
pub const ArchInterruptFrame = InterruptFrame;
pub const InterruptFrame = extern struct {};

pub const init = struct {};

const kernel = @import("kernel");

const core = @import("core");
const lib_riscv = @import("riscv");
const riscv = @import("riscv.zig");
const std = @import("std");

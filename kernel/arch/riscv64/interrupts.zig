// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const disableInterruptsAndHalt = lib_riscv64.instructions.disableInterruptsAndHalt;
pub const enableInterrupts = lib_riscv64.instructions.enableInterrupts;
pub const areEnabled = lib_riscv64.instructions.interruptsEnabled;
pub const disableInterrupts = lib_riscv64.instructions.disableInterrupts;

pub const Interrupt = enum(u8) {
    _,
};
pub const InterruptFrame = extern struct {};

pub const init = struct {};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const riscv64 = @import("riscv64.zig");
const lib_riscv64 = @import("riscv64");

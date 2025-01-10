// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const disableInterruptsAndHalt = lib_arm64.instructions.disableInterruptsAndHalt;
pub const enableInterrupts = lib_arm64.instructions.enableInterrupts;
pub const areEnabled = lib_arm64.instructions.interruptsEnabled;
pub const disableInterrupts = lib_arm64.instructions.disableInterrupts;

pub const Interrupt = enum {};
pub const InterruptFrame = extern struct {};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arm64 = @import("arm64.zig");
const lib_arm64 = @import("arm64");

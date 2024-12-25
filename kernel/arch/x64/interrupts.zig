// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const disableInterruptsAndHalt = lib_x64.instructions.disableInterruptsAndHalt;
pub const disableInterrupts = lib_x64.instructions.disableInterrupts;

const std = @import("std");
const core = @import("core");
const kernel = @import("../../kernel.zig");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");

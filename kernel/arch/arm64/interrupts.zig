// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const disableInterruptsAndHalt = lib_arm64.instructions.disableInterruptsAndHalt;
pub const disableInterrupts = lib_arm64.instructions.disableInterrupts;

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arm64 = @import("arm64.zig");
const lib_arm64 = @import("arm64");

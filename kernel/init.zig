// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub fn initStage1() !void {
    kernel.arch.interrupts.disableInterruptsAndHalt();
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel.zig");

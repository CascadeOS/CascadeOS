// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const aarch64 = @import("aarch64.zig");

pub const spinLoopHint = aarch64.isb;

pub const init = struct {
    pub const EarlyOutputWriter = aarch64.Uart.Writer;
};

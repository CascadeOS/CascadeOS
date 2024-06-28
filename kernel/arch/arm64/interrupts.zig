// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const arm64 = @import("arm64.zig");

pub const init = struct {
    pub fn initInterrupts() void {
        // TODO: Implement interrupt initialization.
    }
};

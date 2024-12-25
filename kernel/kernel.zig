// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");

comptime {
    boot.exportEntryPoints();
}

const std = @import("std");

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");
pub const debug = @import("debug.zig");

pub const init = @import("init.zig");

pub const Panic = debug.Panic;

comptime {
    boot.exportEntryPoints();
}

const std = @import("std");

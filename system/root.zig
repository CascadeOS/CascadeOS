// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! This file is the root of the kernel executable.
//!
//! It is responsible for exporting the boot modules entry points as well as hooking up the interface with the standard library and panic.

comptime {
    boot.exportEntryPoints();
}

pub const std_options: std.Options = .{
    .log_level = kernel.log.log_level,
    .logFn = kernel.log.stdLogImpl,
};

pub const panic = kernel.debug.zigPanic;

const std = @import("std");
const kernel = @import("kernel");
const boot = @import("boot");

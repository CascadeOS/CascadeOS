// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! This file is the root of the kernel executable.
//!
//! It is responsible for:
//!   - Calling into the boot module to export entry points
//!   - Hooking up the interface with the std.log and panic
//!   - Expose the init log implementation to the `kernel` module
//!   - Expose the init entry point to the `boot` module

comptime {
    boot.exportEntryPoints();
}

pub const std_options: std.Options = .{
    .log_level = kernel.log.log_level,
    .logFn = kernel.log.stdLogImpl,
};

pub const Panic = kernel.debug.Panic;

// Expose the init log implementation so that the `kernel` module can access it on @import("root").
pub const initLogImpl: kernel.log.InitLogImpl = init.handleLog;

// Expose the init entry point so that the `boot` module can access it on @import("root").
pub const initEntryPoint = init.initStage1;

const std = @import("std");
const kernel = @import("kernel");
const boot = @import("boot");
const init = @import("init");

// SPDX-License-Identifier: MIT

//! This file acts as the root file of the kernel executable, with `kernel.zig` being a module.
//! This allows files in the kernel module to `@import("kernel")` without hitting "file exists in multiple modules" errors

const std = @import("std");

const kernel = @import("kernel");

comptime {
    _ = kernel;
}

pub const std_options = struct {
    // ensure using `std.log` in the kernel is a compile error
    pub const log_level = @compileError("use `kernel.log` for logging in the kernel");

    // ensure using `std.log` in the kernel is a compile error
    pub const logFn = @compileError("use `kernel.log` for logging in the kernel");
};

pub const panic = kernel.debug.panic;

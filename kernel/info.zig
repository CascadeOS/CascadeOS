// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");

pub const mode: std.builtin.OptimizeMode = builtin.mode;
pub const arch = kernel_options.arch;
pub const version = kernel_options.version;

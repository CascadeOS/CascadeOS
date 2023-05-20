// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");

// Target options
pub const mode: std.builtin.OptimizeMode = builtin.mode;
pub const arch: std.Target.Cpu.Arch = builtin.target.cpu.arch;

// Build options
pub const scopes_to_force_debug = kernel_options.scopes_to_force_debug;
pub const force_debug_log = kernel_options.force_debug_log;

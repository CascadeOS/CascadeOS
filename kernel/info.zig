// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");

pub const mode: std.builtin.OptimizeMode = builtin.mode;
pub const arch = kernel_options.arch;
pub const board = kernel_options.board;
pub const version = kernel_options.version;

pub const scopes_to_force_debug = kernel_options.scopes_to_force_debug;
pub const force_debug_log = kernel_options.force_debug_log;

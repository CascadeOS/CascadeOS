// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const kernel_options = @import("kernel_options");

pub const arch: std.Target.Cpu.Arch = builtin.target.cpu.arch;

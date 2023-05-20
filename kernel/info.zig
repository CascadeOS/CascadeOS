// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

pub const arch: std.Target.Cpu.Arch = builtin.target.cpu;

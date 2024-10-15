// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

gdt: lib_x64.Gdt = .{},
tss: lib_x64.Tss = .{},

double_fault_stack: kernel.Stack,
non_maskable_interrupt_stack: kernel.Stack,

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
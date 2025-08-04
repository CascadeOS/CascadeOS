// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

apic_id: u32,

gdt: lib_x64.Gdt = .{},
tss: lib_x64.Tss = .{},

double_fault_stack: kernel.Task.Stack,
non_maskable_interrupt_stack: kernel.Task.Stack,

const kernel = @import("kernel");

const core = @import("core");
const lib_x64 = @import("x64");
const std = @import("std");
const x64 = @import("x64.zig");

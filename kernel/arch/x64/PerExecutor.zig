// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

apic_id: u32,

gdt: x64.Gdt = .{},
tss: x64.Tss = .{},

double_fault_stack: kernel.Task.Stack,
non_maskable_interrupt_stack: kernel.Task.Stack,

const kernel = @import("kernel");
const x64 = @import("x64.zig");

const core = @import("core");
const std = @import("std");

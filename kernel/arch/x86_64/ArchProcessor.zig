// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

lapic_id: u32,

gdt: x86_64.Gdt = .{},
tss: x86_64.Tss = .{},

double_fault_stack: kernel.Stack,
non_maskable_interrupt_stack: kernel.Stack,

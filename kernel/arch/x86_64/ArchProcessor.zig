// SPDX-License-Identifier: MIT

const core = @import("core");
const Gdt = x86_64.Gdt;
const kernel = @import("kernel");
const Stack = kernel.Stack;
const std = @import("std");
const Tss = x86_64.Tss;
const x86_64 = @import("x86_64.zig");

gdt: Gdt = .{},
tss: Tss = .{},

double_fault_stack: Stack,
non_maskable_interrupt_stack: Stack,

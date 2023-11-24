// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

gdt: x86_64.Gdt = .{},
tss: x86_64.Tss = .{},

interrupt_stack: kernel.Stack,
double_fault_stack: kernel.Stack,
non_maskable_interrupt_stack: kernel.Stack,

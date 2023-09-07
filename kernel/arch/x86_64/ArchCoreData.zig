// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

gdt: x86_64.Gdt = .{},
tss: x86_64.Tss = .{},

exception_stack: []align(16) u8 = undefined,
double_fault_stack: []align(16) u8 = undefined,
interrupt_stack: []align(16) u8 = undefined,
non_maskable_interrupt_stack: []align(16) u8 = undefined,

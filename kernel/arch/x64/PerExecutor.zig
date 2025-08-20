// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

apic_id: u32,

gdt: x64.Gdt = .{},
tss: x64.Tss = .{},

double_fault_stack: cascade.Task.Stack,
non_maskable_interrupt_stack: cascade.Task.Stack,

const cascade = @import("cascade");
const x64 = @import("x64.zig");

const core = @import("core");
const std = @import("std");

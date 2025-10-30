// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const x64 = @import("x64.zig");

apic_id: u32,

gdt: x64.Gdt = .{},
tss: x64.Tss = .{},

double_fault_stack: Task.Stack,
non_maskable_interrupt_stack: Task.Stack,

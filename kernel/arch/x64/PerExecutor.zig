// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const cascade = @import("cascade");

const x64 = @import("x64.zig");

const PerExecutor = @This();

apic_id: u32,

gdt: x64.Gdt = .{},
tss: x64.Tss = .{},

double_fault_stack: cascade.Task.Stack,
non_maskable_interrupt_stack: cascade.Task.Stack,

pub inline fn from(executor: *cascade.Executor) *PerExecutor {
    return &executor.arch_specific;
}

// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const arch = @import("arch");
const cascade = @import("cascade");

pub const apic = @import("apic.zig");
pub const config = @import("config.zig");
pub const Executor = @import("Executor.zig");
pub const Gdt = @import("Gdt.zig").Gdt;
pub const hpet = @import("hpet.zig");
pub const info = @import("info/info.zig");
pub const init = @import("init.zig");
pub const Interrupt = @import("Interrupt.zig").Interrupt;
pub const ioapic = @import("ioapic.zig");
pub const PageTable = @import("PageTable.zig").PageTable;
pub const Port = @import("Port.zig").Port;
pub const registers = @import("registers.zig");
pub const syscall = @import("syscall.zig");
pub const Task = @import("Task.zig");
pub const Thread = @import("Thread.zig");
pub const tsc = @import("tsc.zig");
pub const Tss = @import("Tss.zig").Tss;

pub const PrivilegeLevel = enum(u2) {
    ring0 = 0,
    ring1 = 1,
    ring2 = 2,
    ring3 = 3,
};

/// Copies memory from `source` to `destination`.
///
/// Sets `target` to the address any unhandleable page fault should return to after setting the result in the slot.
pub fn safeMemcpy(
    destination: cascade.VirtualRange,
    source: cascade.VirtualRange,
    target: *cascade.KernelVirtualAddress,
) void {
    asm volatile (
        \\lea 1f(%rip), %rax
        \\mov %rax, (%[target])
        \\
        \\rep movsb
        \\
        \\1:
        :
        : [target] "r" (target),
          [source_ptr] "+{rsi}" (source.address.value),
          [destination_ptr] "+{rdi}" (destination.address.value),
          [count] "+{rcx}" (source.size.value),
        : .{
          .rax = true,
          .rsi = true,
          .rdi = true,
          .rcx = true,
          .memory = true,
        });
}

pub inline fn mfence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

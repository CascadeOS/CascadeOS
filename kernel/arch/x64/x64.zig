// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const apic = @import("apic.zig");
pub const config = @import("config.zig");
pub const Gdt = @import("Gdt.zig").Gdt;
pub const hpet = @import("hpet.zig");
pub const info = @import("info/info.zig");
pub const init = @import("init.zig");
pub const instructions = @import("instructions.zig");
pub const interrupts = @import("interrupts/interrupts.zig");
pub const ioapic = @import("ioapic.zig");
pub const paging = @import("paging/paging.zig");
pub const PerExecutor = @import("PerExecutor.zig");
pub const registers = @import("registers.zig");
pub const scheduling = @import("scheduling.zig");
pub const tsc = @import("tsc.zig");
pub const Tss = @import("Tss.zig").Tss;

pub const PrivilegeLevel = enum(u2) {
    ring0 = 0,
    ring1 = 1,
    ring2 = 2,
    ring3 = 3,
};

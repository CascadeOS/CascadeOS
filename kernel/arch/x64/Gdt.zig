// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const x64 = @import("x64.zig");

/// The Global Descriptor Table for x64.
pub const Gdt = extern struct {
    descriptors: [8]u64 = [_]u64{
        0x0000000000000000, // Null
        0x00A09A0000000000, // 64 bit code
        0x0000920000000000, // 64 bit data
        0x00CFFA000000FFFF | (3 << 45), // Userspace 32 bit code
        0x0000920000000000 | (3 << 45), // Userspace 64 bit data
        0x00A09A0000000000 | (3 << 45), // Userspace 64 bit code
        0, // TSS - set by `setTss`
        0,
    },

    pub const Selector = enum(u16) {
        null = 0x00,
        kernel_code = 0x08,
        kernel_data = 0x10,
        user_code_32bit = 0x18 | 3,
        user_data = 0x20 | 3,
        user_code = 0x28 | 3,
        tss = 0x30,
    };

    pub fn setTss(gdt: *Gdt, tss: *x64.Tss) void {
        const mask_u8: u64 = std.math.maxInt(u8);
        const mask_u16: u64 = std.math.maxInt(u16);
        const mask_u24: u64 = std.math.maxInt(u24);

        const tss_ptr = @intFromPtr(tss);

        const low_base: u64 = (tss_ptr & mask_u24) << 16;
        const mid_base: u64 = ((tss_ptr >> 24) & mask_u8) << 56;

        const high_base: u64 = tss_ptr >> 32;

        const present: u64 = 1 << 47;

        const available_64_bit_tss: u64 = 0b1001 << 40;

        const limit: u64 = (@sizeOf(x64.Tss) - 1) & mask_u16;

        const tss_index = @intFromEnum(Selector.tss) / @sizeOf(u64);

        gdt.descriptors[tss_index] = low_base | mid_base | limit | present | available_64_bit_tss;
        gdt.descriptors[tss_index + 1] = high_base;

        asm volatile ("ltr %[ts_sel]"
            :
            : [ts_sel] "r" (@intFromEnum(Selector.tss)),
        );
    }

    pub fn load(gdt: *Gdt) void {
        const gdt_ptr: Gdtr = .{
            .limit = @sizeOf(Gdt) - 1,
            .base = @intFromPtr(gdt),
        };

        asm volatile (
            \\lgdt %[gdt_ptr]
            \\
            \\mov %[dsel], %%ds
            \\mov %[dsel], %%es
            \\mov %[dsel], %%ss
            \\
            \\xor %%eax, %%eax
            \\mov %%eax, %%fs
            \\mov %%eax, %%gs
            \\
            \\push %[csel]
            \\lea 1f(%%rip), %%rax
            \\push %%rax
            \\.byte 0x48, 0xCB // Far return
            \\1:
            :
            : [gdt_ptr] "*p" (&gdt_ptr),
              [dsel] "r" (@intFromEnum(Selector.kernel_data)),
              [csel] "i" (@intFromEnum(Selector.kernel_code)),
            : .{ .rax = true });
    }

    const Gdtr = packed struct {
        limit: u16,
        base: u64,
    };
};

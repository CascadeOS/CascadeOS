// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// The Global Descriptor Table for x64.
pub const Gdt = extern struct {
    descriptors: [7]u64 = [7]u64{
        0x0000000000000000, // Null
        0x00A09A0000000000, // 64 bit code
        0x0000920000000000, // 64 bit data
        0x00A09A0000000000 | (3 << 45), // Userspace 64 bit code
        0x0000920000000000 | (3 << 45), // Userspace 64 bit data
        0, // TSS - set by `setTss`
        0,
    },

    pub const Selector = enum(u16) {
        null = 0x00,
        kernel_code = 0x08,
        kernel_data = 0x10,
        user_code = 0x18 | 3,
        user_data = 0x20 | 3,
        tss = 0x28,
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

        gdt.descriptors[5] = low_base | mid_base | limit | present | available_64_bit_tss;
        gdt.descriptors[6] = high_base;

        asm volatile (
            \\  ltr %[ts_sel]
            :
            : [ts_sel] "rm" (@intFromEnum(Selector.tss)),
        );
    }

    pub fn load(gdt: *Gdt) void {
        const gdt_ptr = Gdtr{
            .limit = @sizeOf(Gdt) - 1,
            .base = @intFromPtr(gdt),
        };

        // Load the GDT
        asm volatile (
            \\  lgdt %[p]
            :
            : [p] "*p" (&gdt_ptr),
        );

        // Use the data selectors
        asm volatile (
            \\  mov %[dsel], %%ds
            \\  mov %[dsel], %%fs
            \\  mov %[dsel], %%gs
            \\  mov %[dsel], %%es
            \\  mov %[dsel], %%ss
            :
            : [dsel] "rm" (@intFromEnum(Selector.kernel_data)),
        );

        // Use the code selector
        asm volatile (
            \\ push %[csel]
            \\ lea 1f(%%rip), %%rax
            \\ push %%rax
            \\ .byte 0x48, 0xCB // Far return
            \\ 1:
            :
            : [csel] "i" (@intFromEnum(Selector.kernel_code)),
            : "rax"
        );
    }

    const Gdtr = packed struct {
        limit: u16,
        base: u64,
    };
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const core = @import("core");
const std = @import("std");

const x64 = @import("x64");

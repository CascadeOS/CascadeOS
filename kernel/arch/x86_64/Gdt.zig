// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("x86_64.zig");

pub const Gdt = extern struct {
    descriptors: [7]u64 = [7]u64{
        0x0000000000000000, // Null
        0x00A09A0000000000, // 64 bit code
        0x0000920000000000, // 64 bit data
        0x00A09A0000000000 | (3 << 45), // Userspace 64 bit code
        0x0000920000000000 | (3 << 45), // Userspace 64 bit data
        0, // TSS
        0,
    },

    pub const null_selector = @as(u16, 0x00);
    pub const kernel_code_selector = @as(u16, 0x08);
    pub const kernel_data_selector = @as(u16, 0x10);
    pub const user_code_selector = @as(u16, 0x18 | 3);
    pub const user_data_selector = @as(u16, 0x20 | 3);
    pub const tss_selector = @as(u16, 0x28);

    const mask_u8: u64 = std.math.maxInt(u8);
    const mask_u16: u64 = std.math.maxInt(u16);
    const mask_u24: u64 = std.math.maxInt(u24);

    pub fn setTss(self: *Gdt, tss: *x86_64.Tss) void {
        // TODO: packed struct to represent the below

        const tss_ptr = @ptrToInt(tss);

        const low_base: u64 = (tss_ptr & mask_u24) << 16;
        const mid_base: u64 = ((tss_ptr >> 24) & mask_u8) << 56;

        const high_base: u64 = tss_ptr >> 32;

        const present: u64 = 1 << 47;

        const available_64_bit_tss: u64 = 0b1001 << 40;

        const limit: u64 = (@sizeOf(x86_64.Tss) - 1) & mask_u16;

        self.descriptors[5] = low_base | mid_base | limit | present | available_64_bit_tss;
        self.descriptors[6] = high_base;

        asm volatile (
            \\  ltr %[ts_sel]
            :
            : [ts_sel] "rm" (tss_selector),
        );
    }

    pub fn load(self: *Gdt) void {
        const gdt_ptr = Gdtr{
            .limit = @sizeOf(Gdt) - 1,
            .base = @ptrToInt(self),
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
            : [dsel] "rm" (kernel_data_selector),
        );

        // Use the code selector
        asm volatile (
            \\ push %[csel]
            \\ lea 1f(%%rip), %%rax
            \\ push %%rax
            \\ .byte 0x48, 0xCB // Far return
            \\ 1:
            :
            : [csel] "i" (kernel_code_selector),
            : "rax"
        );
    }

    const Gdtr = packed struct {
        limit: u16,
        base: u64,
    };
};

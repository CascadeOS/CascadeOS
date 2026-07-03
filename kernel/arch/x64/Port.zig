// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const x64 = @import("x64.zig");

pub const Port = enum(u16) {
    _,

    pub fn from(value: usize) arch.Port.FromError!Port {
        return @enumFromInt(std.math.cast(u16, value) orelse return error.InvalidPort);
    }

    pub fn readPortU8(port: Port) u8 {
        return asm ("inb %[port], %[ret]"
            : [ret] "={al}" (-> u8),
            : [port] "N{dx}" (@intFromEnum(port)),
        );
    }

    pub fn readPortU16(port: Port) u16 {
        return asm ("inw %[port], %[ret]"
            : [ret] "={ax}" (-> u16),
            : [port] "N{dx}" (@intFromEnum(port)),
        );
    }

    pub fn readPortU32(port: Port) u32 {
        return asm ("inl %[port], %[ret]"
            : [ret] "={eax}" (-> u32),
            : [port] "N{dx}" (@intFromEnum(port)),
        );
    }

    pub fn writePortU8(port: Port, value: u8) void {
        asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (value),
              [port] "N{dx}" (@intFromEnum(port)),
        );
    }

    pub fn writePortU16(port: Port, value: u16) void {
        asm volatile ("outw %[value], %[port]"
            :
            : [value] "{ax}" (value),
              [port] "N{dx}" (@intFromEnum(port)),
        );
    }

    pub fn writePortU32(port: Port, value: u32) void {
        asm volatile ("outl %[value], %[port]"
            :
            : [value] "{eax}" (value),
              [port] "N{dx}" (@intFromEnum(port)),
        );
    }
};

// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

/// Issues a PAUSE instruction.
///
/// The PAUSE instruction improves the performance of spin-wait loops.
pub inline fn pause() void {
    asm volatile ("pause" ::: "memory");
}

/// Issues a HLT instruction.
pub noinline fn halt() void {
    // TODO: The NMI handler will need to check if the IP is equal to __halt_address and if so, it will need to skip the
    // hlt instruction. https://github.com/CascadeOS/CascadeOS/issues/33
    asm volatile (
        \\.globl __halt_address
        \\__halt_address:
        \\hlt
        \\
    );
}

/// Reads a byte from the given I/O port.
pub inline fn portReadU8(port: u16) u8 {
    return asm ("inb %[port],%[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

/// Reads a word (16 bits) from the given I/O port.
pub inline fn portReadU16(port: u16) u16 {
    return asm ("inw %[port],%[ret]"
        : [ret] "={al}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

/// Reads a doubleword (32 bits) from the given I/O port.
pub inline fn portReadU32(port: u16) u32 {
    return asm ("inl %[port],%[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

/// Writes a byte to the given I/O port.
pub inline fn portWriteU8(port: u16, value: u8) void {
    asm volatile ("outb %[value],%[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

/// Writes a word (16 bits) to the given I/O port.
pub inline fn portWriteU16(port: u16, value: u16) void {
    asm volatile ("outw %[value],%[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

/// Writes a doubleword (32 bits) to the given I/O port.
pub inline fn portWriteU32(port: u16, value: u32) void {
    asm volatile ("outl %[value],%[port]"
        :
        : [value] "{eax}" (value),
          [port] "N{dx}" (port),
    );
}

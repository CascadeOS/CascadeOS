// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const std = @import("std");

const x64 = @import("x64");

/// Are interrupts enabled?
pub inline fn interruptsEnabled() bool {
    return x64.RFlags.read().interrupt;
}

/// Enable interrupts.
pub inline fn enableInterrupts() void {
    asm volatile ("sti");
}

/// Disable interrupts.
pub inline fn disableInterrupts() void {
    asm volatile ("cli");
}

/// Disable interrupts and put the CPU to sleep.
pub fn disableInterruptsAndHalt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

pub fn readTsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}

/// Issues a PAUSE instruction.
///
/// The PAUSE instruction improves the performance of spin-wait loops.
pub inline fn pause() void {
    asm volatile ("pause" ::: "memory");
}

/// Issues a HLT instruction.
pub inline fn halt() void {
    asm volatile ("hlt");
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

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .@"struct" => |info| info.decls,
        .@"enum" => |info| info.decls,
        .@"union" => |info| info.decls,
        .@"opaque" => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

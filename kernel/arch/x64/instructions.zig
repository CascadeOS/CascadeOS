// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const core = @import("core");

const x64 = @import("x64.zig");

pub inline fn interruptsEnabled() bool {
    return x64.registers.RFlags.read().interrupt;
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti");
}

pub inline fn disableInterrupts() void {
    asm volatile ("cli");
}

pub inline fn disableInterruptsAndHalt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

pub inline fn invlpg(address: core.VirtualAddress) void {
    asm volatile ("invlpg (%[address])"
        :
        : [address] "{rax}" (address.value),
    );
}

pub inline fn readTsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}

pub inline fn pause() void {
    asm volatile ("pause" ::: .{ .memory = true });
}

pub inline fn halt() void {
    asm volatile ("hlt");
}

pub inline fn portReadU8(port: u16) u8 {
    return asm ("inb %[port],%[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub inline fn portReadU16(port: u16) u16 {
    return asm ("inw %[port],%[ret]"
        : [ret] "={al}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

pub inline fn portReadU32(port: u16) u32 {
    return asm ("inl %[port],%[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

pub inline fn portWriteU8(port: u16, value: u8) void {
    asm volatile ("outb %[value],%[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn portWriteU16(port: u16, value: u16) void {
    asm volatile ("outw %[value],%[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn portWriteU32(port: u16, value: u32) void {
    asm volatile ("outl %[value],%[port]"
        :
        : [value] "{eax}" (value),
          [port] "N{dx}" (port),
    );
}

pub fn enableAccessToUserMemory() void {
    if (!x64.info.cpu_id.smap) {
        @branchHint(.unlikely); // modern CPUs support SMAP
        return;
    }
    asm volatile ("stac");
}

pub fn disableAccessToUserMemory() void {
    if (!x64.info.cpu_id.smap) {
        @branchHint(.unlikely); // modern CPUs support SMAP
        return;
    }
    asm volatile ("clac");
}

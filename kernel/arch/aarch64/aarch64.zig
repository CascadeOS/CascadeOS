// SPDX-License-Identifier: MIT

const arch = kernel.arch;
const core = @import("core");
const info = kernel.info;
const kernel = @import("kernel");
const Processor = kernel.Processor;
const std = @import("std");
const VirtualAddress = kernel.VirtualAddress;

pub const init = @import("init.zig");
pub const registers = @import("registers.zig");
pub const Uart = @import("Uart.zig");

pub inline fn spinLoopHint() void {
    asm volatile ("isb" ::: "memory");
}

pub const ArchProcessor = struct {};

pub inline fn getProcessor() *Processor {
    return @ptrFromInt(registers.TPIDR_EL1.read());
}

pub inline fn earlyGetProcessor() ?*Processor {
    return @ptrFromInt(registers.TPIDR_EL1.read());
}

pub const interrupts = struct {
    /// Disable interrupts and put the CPU to sleep.
    pub fn disableInterruptsAndHalt() noreturn {
        while (true) {
            asm volatile ("msr DAIFSet, #0b1111");
            asm volatile ("wfe");
        }
    }

    /// Disable interrupts.
    pub inline fn disableInterrupts() void {
        asm volatile ("msr DAIFSet, #0b1111");
    }

    /// Enable interrupts.
    pub inline fn enableInterrupts() void {
        asm volatile ("msr DAIFClr, #0b1111;");
    }

    /// Are interrupts enabled?
    pub inline fn interruptsEnabled() bool {
        return false; // TODO: Actually figure this out https://github.com/CascadeOS/CascadeOS/issues/46
    }
};

pub const paging = struct {
    // TODO: Is this correct for aarch64? https://github.com/CascadeOS/CascadeOS/issues/23
    pub const small_page_size = core.Size.from(4, .kib);
    pub const medium_page_size = core.Size.from(2, .mib);
    pub const large_page_size = core.Size.from(1, .gib);

    pub const standard_page_size = small_page_size;

    // TODO: Is this correct for aarch64? https://github.com/CascadeOS/CascadeOS/issues/23
    pub const higher_half = VirtualAddress.fromInt(0xffff800000000000);

    pub const PageTable = struct {};
};

comptime {
    if (info.arch != .aarch64) {
        @compileError("aarch64 implementation has been referenced when building " ++ @tagName(info.arch));
    }
}

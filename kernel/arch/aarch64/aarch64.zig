// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

pub const init = @import("init.zig");
pub const registers = @import("registers.zig");

pub inline fn spinLoopHint() void {
    asm volatile ("isb" ::: "memory");
}

pub const ArchProcessor = struct {};

pub inline fn getProcessor() *kernel.Processor {
    return @ptrFromInt(registers.TPIDR_EL1.read());
}

pub inline fn earlyGetProcessor() ?*kernel.Processor {
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
    pub fn interruptsEnabled() bool {
        const daif = asm ("MRS %[daif], DAIF"
            : [daif] "=r" (-> u64),
        );
        const mask: u64 = 0b1111000000;
        return (daif & mask) == 0;
    }
};

pub const paging = struct {
    pub const small_page_size = core.Size.from(4, .kib);
    pub const medium_page_size = core.Size.from(2, .mib);
    pub const large_page_size = core.Size.from(1, .gib);

    pub const standard_page_size = small_page_size;

    pub const higher_half = kernel.VirtualAddress.fromInt(0xffff800000000000);

    pub const PageTable = struct {};
};

comptime {
    if (kernel.info.arch != .aarch64) {
        @compileError("aarch64 implementation has been referenced when building " ++ @tagName(kernel.info.arch));
    }
}

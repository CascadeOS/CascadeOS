// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

const entry = @import("entry.zig");

pub const port = @import("port.zig");
pub const serial = @import("serial.zig");

comptime {
    // make sure the entry points are referenced
    _ = entry;
}

/// Disable interrupts and put the CPU to sleep.
pub fn disableInterruptsAndHalt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

pub inline fn pause() void {
    asm volatile ("pause");
}

pub const earlyLogFn = entry.earlyLogFn;

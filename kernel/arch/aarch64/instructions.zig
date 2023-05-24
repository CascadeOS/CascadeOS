// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("root");
const aarch64 = @import("aarch64.zig");

/// Disable interrupts and put the CPU to sleep.
pub fn disableInterruptsAndHalt() noreturn {
    while (true) {
        asm volatile ("MSR DAIFSET, #0xF;");
    }
}

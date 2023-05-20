// SPDX-License-Identifier: MIT

const std = @import("std");

export fn _start() callconv(.Naked) void {
    while (true) {}
}

/// Disable interrupts and put the CPU to sleep.
pub fn disableInterruptsAndHalt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("../x86_64.zig");

const interrupts = @import("interrupts.zig");
const InterruptFrame = interrupts.InterruptFrame;

const log = kernel.log.scoped(.interrupts);

/// Handles unhandled interrupts by printing the vector and then panicking.
pub fn unhandledInterrupt(interrupt_frame: *const InterruptFrame) void {
    const idt_vector = interrupt_frame.getIdtVector();

    // TODO: print specific things for each exception, especially page fault https://github.com/CascadeOS/CascadeOS/issues/32
    if (idt_vector.isException()) {
        core.panicFmt("exception {s}", .{@tagName(idt_vector)}) catch unreachable;
    }

    core.panicFmt("interrupt {d}", .{@intFromEnum(idt_vector)}) catch unreachable;
}

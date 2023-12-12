// SPDX-License-Identifier: MIT

const core = @import("core");
const InterruptFrame = interrupts.InterruptFrame;
const interrupts = @import("interrupts.zig");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("../x86_64.zig");

const log = kernel.debug.log.scoped(.interrupts);

/// Handles unhandled interrupts by printing the vector and then panicking.
pub fn unhandledInterrupt(interrupt_frame: *const InterruptFrame) void {
    const idt_vector = interrupt_frame.getIdtVector();

    // TODO: print specific things for each exception, especially page fault https://github.com/CascadeOS/CascadeOS/issues/32
    if (idt_vector.isException()) {
        core.panicFmt("exception: {s}", .{@tagName(idt_vector)}) catch unreachable;
    }

    core.panicFmt("interrupt {d}", .{@intFromEnum(idt_vector)}) catch unreachable;
}

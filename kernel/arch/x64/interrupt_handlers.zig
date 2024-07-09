// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x64 = @import("x64.zig");

const InterruptExclusion = kernel.sync.InterruptExclusion;
const InterruptFrame = x64.interrupts.InterruptFrame;

const log = kernel.log.scoped(.interrupt);

pub fn unhandledInterrupt(
    interrupt_exclusion: kernel.sync.InterruptExclusion,
    interrupt_frame: *const x64.interrupts.InterruptFrame,
) void {
    _ = interrupt_exclusion;
    core.panicFmt("unhandled interrupt\n{}", .{interrupt_frame});
}

pub fn scheduler(
    interrupt_exclusion: InterruptExclusion,
    interrupt_frame: *InterruptFrame,
) void {
    _ = interrupt_frame;

    x64.apic.eoi();

    interrupt_exclusion.release();

    const scheduler_held = kernel.scheduler.acquireScheduler();
    defer scheduler_held.release();

    // TODO: actually implement time slices

    kernel.scheduler.maybePreempt(scheduler_held);
}

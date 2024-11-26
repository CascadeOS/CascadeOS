// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub fn onPerExecutorPeriodic(interrupt_exclusion: *kernel.sync.InterruptExclusion) void {
    // TODO: do more than just preempt on every interrupt

    var scheduler_held = kernel.scheduler.lockScheduler(interrupt_exclusion);
    defer scheduler_held.unlock();

    kernel.scheduler.maybePreempt(scheduler_held);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.log.scoped(.entry);

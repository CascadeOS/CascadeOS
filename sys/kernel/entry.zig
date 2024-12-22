// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub fn onPerExecutorPeriodic(current_task: *kernel.Task) void {
    // TODO: do more than just preempt on every interrupt

    kernel.scheduler.maybePreempt(current_task);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.log.scoped(.entry);

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn onPerExecutorPeriodic(current_task: *kernel.Task) void {
    // TODO: do more than just preempt on every interrupt

    kernel.scheduler.maybePreempt(current_task);
}

pub fn onFlushRequest(current_task: *kernel.Task) void {
    const executor = current_task.state.running;

    while (executor.flush_requests.pop()) |node| {
        const request_node: *const kernel.mem.FlushRequest.Node = @fieldParentPtr("node", node);
        request_node.request.flush(current_task);
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.entry);

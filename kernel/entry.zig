// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn onPerExecutorPeriodic(current_task: *kernel.Task) void {
    // TODO: do more than just preempt on every interrupt

    kernel.scheduler.maybePreempt(current_task);
}

pub fn onPageFault(current_task: *kernel.Task, page_fault_details: kernel.mem.PageFaultDetails) void {
    switch (page_fault_details.source) {
        .kernel => kernel.mem.onKernelPageFault(current_task, page_fault_details),
        .user => std.debug.panic("user page fault\n{}", .{page_fault_details}), // TODO
    }
}

pub fn onFlushRequest(current_task: *kernel.Task) void {
    kernel.mem.FlushRequest.processFlushRequests(current_task);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.entry);

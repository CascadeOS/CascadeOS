// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Executed upon per executor periodic interrupt.
pub fn onPerExecutorPeriodic(current_task: *kernel.Task) void {
    kernel.scheduler.maybePreempt(current_task);
}

/// Executed upon page fault.
pub fn onPageFault(
    current_task: *kernel.Task,
    page_fault_details: kernel.mem.PageFaultDetails,
    interrupt_frame: kernel.arch.interrupts.InterruptFrame,
) void {
    current_task.decrementInterruptDisable();
    switch (page_fault_details.context) {
        .kernel => kernel.mem.onKernelPageFault(
            current_task,
            page_fault_details,
            interrupt_frame,
        ),
        .user => |process| process.address_space.handlePageFault(
            current_task,
            page_fault_details,
        ) catch |err| {
            std.debug.panic("user page fault failed: {s}\n{f}", .{ @errorName(err), page_fault_details });
        },
    }
}

/// Executed upon cross-executor flush request.
pub fn onFlushRequest(current_task: *kernel.Task) void {
    kernel.mem.FlushRequest.processFlushRequests(current_task);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.entry);

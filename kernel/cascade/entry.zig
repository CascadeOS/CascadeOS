// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const log = cascade.debug.log.scoped(.entry);
/// Executed upon per executor periodic interrupt.
///
/// The timers interrupt has already been acknowledged by the architecture specific code.
pub fn onPerExecutorPeriodic(current_task: *cascade.Task) void {
    cascade.scheduler.maybePreempt(current_task);
}

/// Executed upon page fault.
pub fn onPageFault(
    current_task: *cascade.Task,
    page_fault_details: cascade.mem.PageFaultDetails,
    interrupt_frame: arch.interrupts.InterruptFrame,
) void {
    current_task.context.decrementInterruptDisable();
    switch (page_fault_details.faulting_environment) {
        .kernel => cascade.mem.onKernelPageFault(
            current_task,
            page_fault_details,
            interrupt_frame,
        ),
        .user => |process| process.address_space.handlePageFault(
            current_task,
            page_fault_details,
        ) catch |err| {
            std.debug.panic("user page fault failed: {t}\n{f}", .{ err, page_fault_details });
        },
    }
}

/// Executed upon cross-executor flush request.
pub fn onFlushRequest(current_task: *cascade.Task) void {
    cascade.mem.FlushRequest.processFlushRequests(current_task);
}

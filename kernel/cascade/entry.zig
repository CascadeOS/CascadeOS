// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const log = cascade.debug.log.scoped(.entry);

/// Executed upon per executor periodic interrupt.
///
/// The timers interrupt has already been acknowledged by the architecture specific code.
pub fn onPerExecutorPeriodic(current_task: Task.Current) void {
    current_task.maybePreempt();
}

/// Executed upon page fault.
pub fn onPageFault(
    current_task: Task.Current,
    page_fault_details: cascade.mem.PageFaultDetails,
    interrupt_frame: arch.interrupts.InterruptFrame,
) void {
    current_task.decrementInterruptDisable();
    switch (page_fault_details.faulting_context) {
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
pub fn onFlushRequest(current_task: Task.Current) void {
    cascade.mem.FlushRequest.processFlushRequests(current_task);
}

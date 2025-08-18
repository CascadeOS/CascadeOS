// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Executed upon per executor periodic interrupt.
///
/// The timers interrupt has already been acknowledged by the architecture specific code.
pub fn onPerExecutorPeriodic(context: *kernel.Context) void {
    kernel.scheduler.maybePreempt(context);
}

/// Executed upon page fault.
pub fn onPageFault(
    context: *kernel.Context,
    page_fault_details: kernel.mem.PageFaultDetails,
    interrupt_frame: arch.interrupts.InterruptFrame,
) void {
    context.decrementInterruptDisable();
    switch (page_fault_details.environment) {
        .kernel => kernel.mem.onKernelPageFault(
            context,
            page_fault_details,
            interrupt_frame,
        ),
        .user => |process| process.address_space.handlePageFault(
            context,
            page_fault_details,
        ) catch |err| {
            std.debug.panic("user page fault failed: {s}\n{f}", .{ @errorName(err), page_fault_details });
        },
    }
}

/// Executed upon cross-executor flush request.
pub fn onFlushRequest(context: *kernel.Context) void {
    kernel.mem.FlushRequest.processFlushRequests(context);
}

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const log = kernel.debug.log.scoped(.entry);
const std = @import("std");

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

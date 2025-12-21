// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

pub const Process = @import("Process.zig");
pub const Thread = @import("Thread.zig");

const log = cascade.debug.log.scoped(.user);

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.user_init);

    pub fn initialize(current_task: Task.Current) !void {
        init_log.debug(current_task, "initializing processes", .{});
        try Process.init.initializeProcesses(current_task);

        init_log.debug(current_task, "initializing threads", .{});
        try Thread.init.initializeThreads(current_task);

        try arch.user.init.initialize(current_task);
    }
};

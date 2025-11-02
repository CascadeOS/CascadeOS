// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a userspace thread.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Process = cascade.Process;
const core = @import("core");

const log = cascade.debug.log.scoped(.thread);

const Thread = @This();

task: Task,

process: *Process,

pub inline fn fromTask(task: *Task) *Thread {
    if (core.is_debug) std.debug.assert(task.type == .user);
    return @fieldParentPtr("task", task);
}

pub const internal = struct {
    pub fn create(
        current_task: *Task,
        process: *Process,
        options: Task.internal.InitOptions,
    ) !*Thread {
        const thread = try globals.cache.allocate(current_task);
        errdefer globals.cache.deallocate(current_task, thread);

        try Task.internal.init(&thread.task, options);
        thread.process = process;

        return thread;
    }

    pub fn destroy(current_task: *Task, thread: *Thread) void {
        if (core.is_debug) {
            const task = &thread.task;
            std.debug.assert(task.type == .user);
            std.debug.assert(task.state == .dropped);
            std.debug.assert(task.reference_count.load(.monotonic) == 0);
        }
        globals.cache.deallocate(current_task, thread);
    }
};

const globals = struct {
    /// The source of thread objects.
    ///
    /// Initialized during `init.initializeThreads`.
    var cache: cascade.mem.cache.Cache(
        Thread,
        struct {
            fn constructor(thread: *Thread, current_task: *Task) cascade.mem.cache.ConstructorError!void {
                if (core.is_debug) thread.* = undefined;
                thread.task.stack = try .createStack(current_task);
            }
        }.constructor,
        struct {
            fn destructor(thread: *Thread, current_task: *Task) void {
                thread.task.stack.destroyStack(current_task);
            }
        }.destructor,
    ) = undefined;
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.thread_init);

    pub fn initializeThreads(current_task: *Task) !void {
        init_log.debug(current_task, "initializing thread cache", .{});
        globals.cache.init(
            current_task,
            .{ .name = try .fromSlice("thread") },
        );
    }
};

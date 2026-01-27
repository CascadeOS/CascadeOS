// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Represents a userspace thread.

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const Process = kernel.user.Process;
const core = @import("core");

const log = kernel.debug.log.scoped(.user);

const Thread = @This();

task: Task,

process: *Process,

arch_specific: arch.user.PerThread,

pub inline fn from(task: *Task) *Thread {
    if (core.is_debug) std.debug.assert(task.type == .user);
    return @fieldParentPtr("task", task);
}

pub inline fn fromConst(task: *const Task) *const Thread {
    if (core.is_debug) std.debug.assert(task.type == .user);
    return @fieldParentPtr("task", task);
}

pub fn format(thread: *const Thread, writer: *std.Io.Writer) !void {
    return thread.task.format(writer);
}

pub const internal = struct {
    pub fn create(
        process: *Process,
        options: Task.internal.InitOptions,
    ) !*Thread {
        const thread = try globals.cache.allocate();
        errdefer globals.cache.deallocate(thread);

        thread.* = .{
            .task = thread.task, // reinitialized below
            .process = process,
            .arch_specific = thread.arch_specific, // reinitialized below
        };

        try Task.internal.init(&thread.task, options);
        arch.user.initializeThread(thread);

        return thread;
    }

    pub fn destroy(thread: *Thread) void {
        if (core.is_debug) {
            const task = &thread.task;
            std.debug.assert(task.type == .user);
            std.debug.assert(task.state == .dropped);
            std.debug.assert(task.reference_count.load(.monotonic) == 0);
        }
        globals.cache.deallocate(thread);
    }
};

const globals = struct {
    /// The source of thread objects.
    ///
    /// Initialized during `init.initializeThreads`.
    var cache: kernel.mem.cache.Cache(
        Thread,
        struct {
            fn constructor(thread: *Thread) kernel.mem.cache.ConstructorError!void {
                if (core.is_debug) thread.* = undefined;
                thread.task.stack = try .createStack();
                errdefer thread.task.stack.destroyStack();
                try arch.user.createThread(thread);
            }
        }.constructor,
        struct {
            fn destructor(thread: *Thread) void {
                arch.user.destroyThread(thread);
                thread.task.stack.destroyStack();
            }
        }.destructor,
    ) = undefined;
};

pub const init = struct {
    const init_log = kernel.debug.log.scoped(.user_init);

    pub fn initializeThreads() !void {
        init_log.debug("initializing thread cache", .{});
        globals.cache.init(
            .{ .name = try .fromSlice("thread") },
        );
    }
};

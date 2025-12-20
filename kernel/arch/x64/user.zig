// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Process = cascade.Process;
const Thread = Process;
const core = @import("core");

const x64 = @import("x64.zig");

pub const PerThread = struct {
    xsave_area: []align(64) u8,
    xsave_area_needs_load: bool = true,
};

/// Create the `PerThread` data of a thread.
///
/// Non-architecture specific creation has already been performed but no initialization.
///
/// This function is called in the `Thread` cache constructor.
pub fn createThread(
    current_task: Task.Current,
    thread: *cascade.Process.Thread,
) cascade.mem.cache.ConstructorError!void {
    thread.arch_specific = .{
        .xsave_area = @alignCast(
            globals.xsave_area_cache.allocate(current_task) catch return error.ItemConstructionFailed,
        ),
    };
}

/// Destroy the `PerThread` data of a thread.
///
/// Non-architecture specific destruction has not already been performed.
///
/// This function is called in the `Thread` cache destructor.
pub fn destroyThread(current_task: Task.Current, thread: *cascade.Process.Thread) void {
    globals.xsave_area_cache.deallocate(current_task, thread.arch_specific.xsave_area);
}

/// Initialize the `PerThread` data of a thread.
///
/// All non-architecture specific initialization has already been performed.
///
/// This function is called in `Thread.internal.create`.
pub fn initializeThread(current_task: Task.Current, thread: *cascade.Process.Thread) void {
    _ = current_task;
    @memset(thread.arch_specific.xsave_area, 0);
    thread.arch_specific.xsave_area_needs_load = true;
}

const globals = struct {
    /// Initialized during `init.initialize`.
    var xsave_area_cache: cascade.mem.cache.RawCache = undefined;
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.thread_init);

    /// Perform any per-achitecture initialization needed for userspace processes/threads.
    pub fn initialize(current_task: Task.Current) !void {
        init_log.debug(current_task, "initializing xsave area cache", .{});
        globals.xsave_area_cache.init(current_task, .{
            .name = try .fromSlice("xsave"),
            .size = x64.info.xsave.xsave_area_size.value,
            .alignment = .fromByteUnits(64),
        });
    }
};

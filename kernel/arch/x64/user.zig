// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Process = cascade.Process;
const Thread = Process.Thread;
const core = @import("core");

const x64 = @import("x64.zig");

pub const PerThread = struct {
    xsave: XSave,

    pub const XSave = struct {
        area: []align(64) u8,

        /// Where is the xsave data currently stored.
        state: State = .area,

        pub const State = enum {
            registers,
            area,
        };

        pub fn zero(xsave: *XSave) void {
            @memset(xsave.area, 0);
            xsave.state = .area;
        }

        /// Save the xsave state into the xsave area if it is currently stored in the registers.
        ///
        /// Caller must ensure SSE is enabled before calling; see `x64.instructions.enableSSEUsage`
        pub fn save(xsave: *XSave) void {
            switch (xsave.state) {
                .area => {},
                .registers => {
                    switch (x64.info.xsave.method) {
                        .xsaveopt => {
                            @branchHint(.likely); // modern machines support xsaveopt
                            x64.instructions.xsaveopt(
                                xsave.area,
                                x64.info.xsave.xcr0_value,
                            );
                        },
                        .xsave => x64.instructions.xsave(
                            xsave.area,
                            x64.info.xsave.xcr0_value,
                        ),
                    }
                    xsave.state = .area;
                },
            }
        }

        /// Load the xsave state into registers if it is currently stored in the xsave area.
        ///
        /// Caller must ensure SSE is enabled before calling; see `x64.instructions.enableSSEUsage`
        pub fn load(xsave: *XSave) void {
            switch (xsave.state) {
                .area => {
                    x64.instructions.xrstor(
                        xsave.area,
                        x64.info.xsave.xcr0_value,
                    );
                    xsave.state = .registers;
                },
                .registers => {},
            }
        }
    };
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
        .xsave = .{
            .area = @alignCast(
                globals.xsave_area_cache.allocate(current_task) catch return error.ItemConstructionFailed,
            ),
        },
    };
}

/// Destroy the `PerThread` data of a thread.
///
/// Non-architecture specific destruction has not already been performed.
///
/// This function is called in the `Thread` cache destructor.
pub fn destroyThread(current_task: Task.Current, thread: *cascade.Process.Thread) void {
    globals.xsave_area_cache.deallocate(current_task, thread.arch_specific.xsave.area);
}

/// Initialize the `PerThread` data of a thread.
///
/// All non-architecture specific initialization has already been performed.
///
/// This function is called in `Thread.internal.create`.
pub fn initializeThread(current_task: Task.Current, thread: *cascade.Process.Thread) void {
    _ = current_task;
    thread.arch_specific.xsave.zero();
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

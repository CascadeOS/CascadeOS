// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

pub const wallclock = struct {
    /// This is an opaque timer tick, to acquire an actual time value, use `elapsed`.
    pub const Tick = enum(u64) {
        zero = 0,

        _,
    };

    /// Read the wallclock value.
    pub inline fn read() Tick {
        return globals.readFn();
    }

    /// Returns the duration between `value1` and `value2`, where `value2 >= value1`.
    ///
    /// Counter wraparound is assumed to have not occured.
    pub inline fn elapsed(value1: Tick, value2: Tick) core.Duration {
        return globals.elapsedFn(value1, value2);
    }

    pub const globals = struct {
        /// Set by `init.time.initializeTime`.
        pub var readFn: *const fn () Tick = undefined;

        /// Set by `init.time.initializeTime`.
        pub var elapsedFn: *const fn (value1: Tick, value2: Tick) core.Duration = undefined;
    };
};

pub const per_executor_periodic = struct {
    /// Enables a per-executor scheduler interrupt to be delivered every `period`.
    pub inline fn enableInterrupt(period: core.Duration) void {
        return globals.enableInterruptFn(period);
    }

    pub const globals = struct {
        /// Set by `init.time.initializeTime`.
        pub var enableInterruptFn: *const fn (period: core.Duration) void = undefined;
    };
};

/// Femptoseconds per nanosecond.
pub const fs_per_ns = 1000000;

/// Femptoseconds per second.
pub const fs_per_s = fs_per_ns * std.time.ns_per_s;
